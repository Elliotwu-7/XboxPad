use std::cmp::Ordering;
use std::collections::{BTreeMap, VecDeque};
use std::time::{Duration, Instant};

use rtp::packet::Packet;

const ANNEX_B_START_CODE: [u8; 4] = [0, 0, 0, 1];

#[derive(Debug, Clone)]
pub struct AssembledAccessUnit {
    pub data: Vec<u8>,
    pub rtp_timestamp: u32,
    pub keyframe: bool,
    pub has_param_sets: bool,
    pub incomplete: bool,
    pub dropped_packets: u16,
    pub first_arrival: Instant,
}

#[derive(Debug)]
struct FrameAssembly {
    rtp_timestamp: u32,
    first_arrival: Instant,
    last_arrival: Instant,
    packets: BTreeMap<u16, Packet>,
    marker_seq: Option<u16>,
    min_seq: u16,
    max_seq: u16,
}

impl FrameAssembly {
    fn new(pkt: Packet, now: Instant) -> Self {
        let seq = pkt.header.sequence_number;
        let marker_seq = if pkt.header.marker { Some(seq) } else { None };
        let ts = pkt.header.timestamp;
        let mut packets = BTreeMap::new();
        packets.insert(seq, pkt);
        Self {
            rtp_timestamp: ts,
            first_arrival: now,
            last_arrival: now,
            packets,
            marker_seq,
            min_seq: seq,
            max_seq: seq,
        }
    }

    fn insert(&mut self, pkt: Packet, now: Instant) {
        let seq = pkt.header.sequence_number;
        if pkt.header.marker {
            self.marker_seq = Some(seq);
        }
        if seq_less(seq, self.min_seq) {
            self.min_seq = seq;
        }
        if seq_less(self.max_seq, seq) {
            self.max_seq = seq;
        }
        self.last_arrival = now;
        self.packets.insert(seq, pkt);
    }

    /// True if the lowest-sequence packet in this frame begins cleanly on an H.264 NAL boundary
    /// (Single NAL, STAP-A, or FU-A with start bit S=1).
    fn starts_cleanly(&self) -> bool {
        let Some(pkt) = self.packets.get(&self.min_seq) else {
            return false;
        };
        let payload = pkt.payload.as_ref();
        if payload.is_empty() {
            return false;
        }
        let nal_type = payload[0] & 0x1F;
        match nal_type {
            1..=24 => true,
            28 => payload.len() >= 2 && (payload[1] & 0x80) != 0,
            _ => false,
        }
    }

    /// True if we have received the RTP marker packet AND every sequence number from
    /// `start_seq` through `marker_seq` without gaps (excluding known RTP padding-only seqs).
    /// When `last_frame_was_incomplete` is true (e.g. previous frame lost its tail packet),
    /// an intact frame whose `min_seq` begins cleanly on a NAL boundary is accepted without
    /// falsely penalizing it for the previous frame's already-dropped tail.
    fn is_complete(
        &self,
        last_emitted_seq: Option<u16>,
        last_frame_incomplete: bool,
        padding_seqs: &VecDeque<u16>,
    ) -> bool {
        let Some(end_seq) = self.marker_seq else {
            return false;
        };
        let start_seq = match last_emitted_seq {
            Some(prev) => {
                let expected = prev.wrapping_add(1);
                if seq_less_eq(expected, self.min_seq) && seq_diff(end_seq, expected) < 512 {
                    if last_frame_incomplete && expected != self.min_seq && self.starts_cleanly() {
                        self.min_seq
                    } else {
                        expected
                    }
                } else {
                    self.min_seq
                }
            }
            None => self.min_seq,
        };
        if seq_less(end_seq, start_seq) {
            return false;
        }
        let span = seq_diff(end_seq, start_seq) as usize + 1;
        let mut cur = start_seq;
        for _ in 0..span {
            if !self.packets.contains_key(&cur) && !padding_seqs.contains(&cur) {
                return false;
            }
            cur = cur.wrapping_add(1);
        }
        true
    }

    /// Depacketize RFC 6184 H.264 RTP packets in sequence order into an Annex-B Access Unit.
    fn assemble(
        self,
        last_emitted_seq: Option<u16>,
        last_frame_incomplete: bool,
        padding_seqs: &VecDeque<u16>,
    ) -> (AssembledAccessUnit, u16) {
        let starts_clean = self.starts_cleanly();
        let mut ordered_seqs: Vec<u16> = self.packets.keys().copied().collect();
        // Sort properly around 16-bit sequence wraparound relative to min_seq
        let base = self.min_seq;
        ordered_seqs.sort_by_key(|&s| s.wrapping_sub(base));

        let mut missing_packets = 0u16;
        if let Some(prev) = last_emitted_seq {
            let expected = prev.wrapping_add(1);
            if seq_less(expected, self.min_seq) && !(last_frame_incomplete && starts_clean) {
                let gap = seq_diff(self.min_seq, expected);
                if gap < 512 {
                    let mut cur = expected;
                    for _ in 0..gap {
                        if !padding_seqs.contains(&cur) {
                            missing_packets = missing_packets.saturating_add(1);
                        }
                        cur = cur.wrapping_add(1);
                    }
                }
            }
        }

        let mut prev_seq: Option<u16> = None;
        let mut out = Vec::with_capacity(self.packets.len() * 1200);
        let mut fu_active = false;
        let mut fu_broken = false;
        let mut keyframe = false;
        let mut has_param_sets = false;

        for seq in &ordered_seqs {
            if let Some(p) = prev_seq {
                let gap = seq.wrapping_sub(p.wrapping_add(1));
                if gap > 0 {
                    let mut real_gap = 0u16;
                    let mut cur = p.wrapping_add(1);
                    for _ in 0..gap {
                        if !padding_seqs.contains(&cur) {
                            real_gap = real_gap.saturating_add(1);
                        }
                        cur = cur.wrapping_add(1);
                    }
                    if real_gap > 0 {
                        missing_packets = missing_packets.saturating_add(real_gap);
                        if fu_active {
                            fu_broken = true;
                        }
                    }
                }
            }
            prev_seq = Some(*seq);

            let Some(pkt) = self.packets.get(seq) else {
                continue;
            };
            let payload = pkt.payload.as_ref();
            if payload.is_empty() {
                continue;
            }

            let nal_type = payload[0] & 0x1F;
            match nal_type {
                // Single NAL unit (1..=23)
                1..=23 => {
                    fu_active = false;
                    fu_broken = false;
                    if nal_type == 5 {
                        keyframe = true;
                    } else if nal_type == 7 || nal_type == 8 {
                        has_param_sets = true;
                    }
                    out.extend_from_slice(&ANNEX_B_START_CODE);
                    out.extend_from_slice(payload);
                }
                // STAP-A (24): aggregated NAL units [2-byte BE size][NAL]...
                24 => {
                    fu_active = false;
                    fu_broken = false;
                    let mut off = 1usize;
                    while off + 2 <= payload.len() {
                        let size = u16::from_be_bytes([payload[off], payload[off + 1]]) as usize;
                        off += 2;
                        if size == 0 || off + size > payload.len() {
                            break;
                        }
                        let inner_type = payload[off] & 0x1F;
                        if inner_type == 5 {
                            keyframe = true;
                        } else if inner_type == 7 || inner_type == 8 {
                            has_param_sets = true;
                        }
                        out.extend_from_slice(&ANNEX_B_START_CODE);
                        out.extend_from_slice(&payload[off..off + size]);
                        off += size;
                    }
                }
                // FU-A (28): fragmented NAL unit
                28 => {
                    if payload.len() < 2 {
                        continue;
                    }
                    let fu_indicator = payload[0];
                    let fu_header = payload[1];
                    let start_bit = (fu_header & 0x80) != 0;
                    let end_bit = (fu_header & 0x40) != 0;
                    let orig_nal_type = fu_header & 0x1F;

                    if start_bit {
                        let reconstructed_header = (fu_indicator & 0xE0) | orig_nal_type;
                        if orig_nal_type == 5 {
                            keyframe = true;
                        } else if orig_nal_type == 7 || orig_nal_type == 8 {
                            has_param_sets = true;
                        }
                        out.extend_from_slice(&ANNEX_B_START_CODE);
                        out.push(reconstructed_header);
                        out.extend_from_slice(&payload[2..]);
                        fu_active = !end_bit;
                        fu_broken = false;
                    } else if fu_active && !fu_broken {
                        out.extend_from_slice(&payload[2..]);
                        if end_bit {
                            fu_active = false;
                        }
                    } else {
                        missing_packets = missing_packets.saturating_add(1);
                    }
                }
                _ => {
                    // Ignore unsupported aggregation types (STAP-B/MTAP/FU-B) gracefully
                }
            }
        }

        let end_seq = self.marker_seq.unwrap_or(self.max_seq);
        let incomplete = missing_packets > 0 || self.marker_seq.is_none() || fu_broken || fu_active;
        let dropped_packets = if incomplete && missing_packets == 0 {
            1
        } else {
            missing_packets
        };

        (
            AssembledAccessUnit {
                data: out,
                rtp_timestamp: self.rtp_timestamp,
                keyframe,
                has_param_sets,
                incomplete,
                dropped_packets,
                first_arrival: self.first_arrival,
            },
            end_seq,
        )
    }
}

/// Zero-wait marker-triggered H.264 RTP depacketizer for ultra-low-latency streaming.
/// Emits complete frames at 0ms the instant the RTP marker bit arrives, instead of waiting
/// for the next frame's timestamp or a long jitter timeout.
pub struct LowLatencyH264Assembler {
    frames: Vec<FrameAssembly>,
    padding_seqs: VecDeque<u16>,
    last_emitted_seq: Option<u16>,
    last_emitted_ts: Option<u32>,
    last_frame_incomplete: bool,
    max_reorder_wait: Duration,
}

impl LowLatencyH264Assembler {
    pub fn new(max_reorder_wait: Duration) -> Self {
        Self {
            frames: Vec::with_capacity(16),
            padding_seqs: VecDeque::with_capacity(64),
            last_emitted_seq: None,
            last_emitted_ts: None,
            last_frame_incomplete: false,
            max_reorder_wait: max_reorder_wait
                .clamp(Duration::from_millis(35), Duration::from_millis(280)),
        }
    }

    pub fn set_max_reorder_wait(&mut self, max_reorder_wait: Duration) {
        self.max_reorder_wait =
            max_reorder_wait.clamp(Duration::from_millis(35), Duration::from_millis(280));
    }

    pub fn has_pending_frames(&self) -> bool {
        !self.frames.is_empty()
    }

    /// Flush any stalled/incomplete head frames whose reorder timeout has expired even when no
    /// new RTP packets arrive (e.g. lost marker packet on a static scene or cellular dip).
    pub fn flush_expired(&mut self) -> Vec<AssembledAccessUnit> {
        if self.frames.is_empty() {
            return Vec::new();
        }
        self.drain_ready(Instant::now())
    }

    pub fn push(&mut self, pkt: Packet) -> Vec<AssembledAccessUnit> {
        let now = Instant::now();
        let ts = pkt.header.timestamp;
        let seq = pkt.header.sequence_number;

        // Track pure RTP padding packets so they never look like missing media packets
        if pkt.payload.is_empty() {
            if !self.padding_seqs.contains(&seq) {
                if self.padding_seqs.len() >= 128 {
                    self.padding_seqs.pop_front();
                }
                self.padding_seqs.push_back(seq);
            }
            if let Some(prev) = self.last_emitted_seq {
                if seq == prev.wrapping_add(1) {
                    self.last_emitted_seq = Some(seq);
                }
            }
            return self.drain_ready(now);
        }

        // Drop packets belonging to already-emitted older timestamps
        if let Some(last_ts) = self.last_emitted_ts {
            if ts == last_ts || ts_less(ts, last_ts) {
                return Vec::new();
            }
        }

        if let Some(frame) = self.frames.iter_mut().find(|f| f.rtp_timestamp == ts) {
            frame.insert(pkt, now);
        } else {
            self.frames.push(FrameAssembly::new(pkt, now));
            // Keep oldest RTP timestamp at index 0 using wrap-safe comparison
            if self.frames.len() > 1 {
                self.frames.sort_by(|a, b| {
                    if a.rtp_timestamp == b.rtp_timestamp {
                        Ordering::Equal
                    } else if ts_less(a.rtp_timestamp, b.rtp_timestamp) {
                        Ordering::Less
                    } else {
                        Ordering::Greater
                    }
                });
            }
        }

        self.drain_ready(now)
    }

    fn drain_ready(&mut self, now: Instant) -> Vec<AssembledAccessUnit> {
        let mut ready = Vec::new();

        while !self.frames.is_empty() {
            // Case 1: Oldest frame is completely assembled (marker received + contiguous seqs) -> emit immediately (0ms wait!)
            if self.frames[0].is_complete(
                self.last_emitted_seq,
                self.last_frame_incomplete,
                &self.padding_seqs,
            ) {
                let frame = self.frames.remove(0);
                let (au, end_seq) = frame.assemble(
                    self.last_emitted_seq,
                    self.last_frame_incomplete,
                    &self.padding_seqs,
                );
                self.last_emitted_seq = Some(end_seq);
                self.last_emitted_ts = Some(au.rtp_timestamp);
                self.last_frame_incomplete = au.incomplete;
                ready.push(au);
                continue;
            }

            // Case 2: Wait up to max_reorder_wait so fast 12ms NACK can recover a missing packet before giving up;
            // scale frame backlog ceiling with max_reorder_wait so high-RTT WAN links (70-160ms) can complete NACK recovery.
            let newer_complete = self
                .frames
                .iter()
                .skip(1)
                .any(|f| f.marker_seq.is_some());
            let oldest_age = now.duration_since(self.frames[0].first_arrival);
            let max_queued_frames =
                ((self.max_reorder_wait.as_millis() as usize / 16) + 3).clamp(8, 20);
            if self.frames.len() >= max_queued_frames
                || (newer_complete && oldest_age >= self.max_reorder_wait)
                || oldest_age >= self.max_reorder_wait * 2
            {
                let frame = self.frames.remove(0);
                let (au, end_seq) = frame.assemble(
                    self.last_emitted_seq,
                    self.last_frame_incomplete,
                    &self.padding_seqs,
                );
                self.last_emitted_seq = Some(end_seq);
                self.last_emitted_ts = Some(au.rtp_timestamp);
                self.last_frame_incomplete = au.incomplete;
                ready.push(au);
                continue;
            }

            break;
        }

        ready
    }
}

#[inline]
fn seq_less(a: u16, b: u16) -> bool {
    let diff = b.wrapping_sub(a);
    diff > 0 && diff < 0x8000
}

#[inline]
fn seq_less_eq(a: u16, b: u16) -> bool {
    a == b || seq_less(a, b)
}

#[inline]
fn seq_diff(end: u16, start: u16) -> u16 {
    end.wrapping_sub(start)
}

#[inline]
fn ts_less(a: u32, b: u32) -> bool {
    let diff = b.wrapping_sub(a);
    diff > 0 && diff < 0x8000_0000
}

#[cfg(test)]
mod tests {
    use super::*;
    use bytes::Bytes;
    use rtp::header::Header;

    fn make_pkt(seq: u16, ts: u32, marker: bool, payload: Vec<u8>) -> Packet {
        Packet {
            header: Header {
                sequence_number: seq,
                timestamp: ts,
                marker,
                ..Default::default()
            },
            payload: Bytes::from(payload),
        }
    }

    #[test]
    fn emits_single_nalu_immediately_on_marker() {
        let mut asm = LowLatencyH264Assembler::new(Duration::from_millis(25));
        let pkt = make_pkt(10, 90000, true, vec![0x65, 0x88, 0x84]); // IDR
        let out = asm.push(pkt);
        assert_eq!(out.len(), 1);
        assert!(out[0].keyframe);
        assert!(!out[0].incomplete);
        assert_eq!(out[0].data, vec![0, 0, 0, 1, 0x65, 0x88, 0x84]);
    }

    #[test]
    fn reassembles_fua_even_when_out_of_order() {
        let mut asm = LowLatencyH264Assembler::new(Duration::from_millis(25));
        // FU-A for IDR (type 5, NRI 0x60 -> indicator 0x7C)
        let p2 = make_pkt(101, 180000, true, vec![0x7C, 0x45, 0xCC, 0xDD]); // end bit
        let p1 = make_pkt(100, 180000, false, vec![0x7C, 0x85, 0xAA, 0xBB]); // start bit

        // First deliver packet 2 (marker), frame shouldn't emit yet since packet 1 missing after setting baseline
        let _ = asm.push(make_pkt(99, 90000, true, vec![0x67, 0x42]));
        assert!(asm.push(p2).is_empty());

        let out = asm.push(p1);
        assert_eq!(out.len(), 1);
        assert!(out[0].keyframe);
        assert!(!out[0].incomplete);
        assert_eq!(out[0].data, vec![0, 0, 0, 1, 0x65, 0xAA, 0xBB, 0xCC, 0xDD]);
    }

    #[test]
    fn unpacks_stap_a_sps_pps_idr() {
        let mut asm = LowLatencyH264Assembler::new(Duration::from_millis(25));
        let mut stap = vec![24u8]; // STAP-A
        stap.extend_from_slice(&2u16.to_be_bytes());
        stap.extend_from_slice(&[0x67, 0x42]); // SPS
        stap.extend_from_slice(&2u16.to_be_bytes());
        stap.extend_from_slice(&[0x68, 0xCE]); // PPS
        stap.extend_from_slice(&3u16.to_be_bytes());
        stap.extend_from_slice(&[0x65, 0x01, 0x02]); // IDR

        let out = asm.push(make_pkt(1, 3000, true, stap));
        assert_eq!(out.len(), 1);
        assert!(out[0].keyframe);
        assert!(out[0].has_param_sets);
        assert_eq!(
            out[0].data,
            vec![0, 0, 0, 1, 0x67, 0x42, 0, 0, 0, 1, 0x68, 0xCE, 0, 0, 0, 1, 0x65, 0x01, 0x02]
        );
    }

    #[test]
    fn handles_padding_packets_without_blocking_emission() {
        let mut asm = LowLatencyH264Assembler::new(Duration::from_millis(25));
        let out1 = asm.push(make_pkt(10, 1000, true, vec![0x65, 0x01]));
        assert_eq!(out1.len(), 1);
        // Padding packet arrives after frame 2 already started
        assert!(asm.push(make_pkt(12, 2500, true, vec![0x41, 0x02])).is_empty());
        let out2 = asm.push(make_pkt(11, 2500, false, vec![])); // empty padding packet
        assert_eq!(out2.len(), 1);
        assert!(!out2[0].incomplete);
        assert_eq!(out2[0].dropped_packets, 0);
    }

    #[test]
    fn sorts_out_of_order_frame_timestamps_oldest_first() {
        let mut asm = LowLatencyH264Assembler::new(Duration::from_millis(25));
        let _ = asm.push(make_pkt(1, 1000, true, vec![0x65, 0x01]));
        // Frame at ts=4000 arrives before ts=2500
        assert!(asm.push(make_pkt(3, 4000, true, vec![0x41, 0x03])).is_empty());
        let out = asm.push(make_pkt(2, 2500, true, vec![0x41, 0x02]));
        assert_eq!(out.len(), 2);
        assert_eq!(out[0].rtp_timestamp, 2500);
        assert_eq!(out[1].rtp_timestamp, 4000);
    }

    #[test]
    fn clean_next_frame_does_not_inherit_previous_dropped_tail() {
        let mut asm = LowLatencyH264Assembler::new(Duration::from_millis(35));
        // Frame 1 starts at seq=10, loses tail packet seq=11 (marker), gets force-flushed by backlog
        let _ = asm.push(make_pkt(10, 1000, false, vec![0x7C, 0x85, 0xAA]));
        // Push 7 newer frames to trigger backlog flush of frame 1 (seq 12..18, leaving gap at seq 11)
        let mut emitted = Vec::new();
        for i in 0..7u16 {
            let seq = 12 + i;
            let ts = 2500 + u32::from(i) * 1500;
            emitted.extend(asm.push(make_pkt(seq, ts, true, vec![0x41, i as u8])));
        }
        assert!(emitted.len() >= 2);
        assert!(emitted[0].incomplete); // Frame 1 was missing its tail
        assert!(emitted[0].dropped_packets >= 1); // Missing marker/tail must report >= 1 dropped packet
        assert!(!emitted[1].incomplete); // Frame 2 starts cleanly on single NAL -> MUST NOT be marked incomplete!
        assert_eq!(emitted[1].dropped_packets, 0);
    }
}
