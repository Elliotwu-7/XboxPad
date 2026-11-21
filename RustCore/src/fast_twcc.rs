use std::sync::{Arc, Mutex as StdMutex};
use std::time::{Duration, Instant};

use async_trait::async_trait;
use rtp::extension::transport_cc_extension::TransportCcExtension;
use tokio::sync::watch;
use tokio::time::MissedTickBehavior;
use webrtc::interceptor::stream_info::StreamInfo;
use webrtc::interceptor::twcc::Recorder;
use webrtc::interceptor::{
    Attributes, Error as InterceptorError, Interceptor, InterceptorBuilder, RTCPReader, RTCPWriter,
    RTPReader, RTPWriter,
};
use webrtc::sdp::extmap::TRANSPORT_CC_URI;
use webrtc::util::Unmarshal;

/// High-throughput, completely non-blocking TWCC receiver interceptor.
///
/// Replaces `webrtc-rs`'s stock `interceptor::twcc::receiver::Receiver`, which funnels every
/// incoming RTP packet through a capacity-1 `mpsc::channel(1)` and stalls `track.read_rtp()`
/// whenever an RTCP write is in flight — causing artificial jitter spikes, UDP buffer drops,
/// and Xbox GCC bitrate collapse.
pub struct FastTwccReceiverBuilder {
    interval: Duration,
}

impl FastTwccReceiverBuilder {
    pub fn new(interval: Duration) -> Self {
        Self { interval }
    }
}

impl InterceptorBuilder for FastTwccReceiverBuilder {
    fn build(
        &self,
        _id: &str,
    ) -> Result<Arc<dyn Interceptor + Send + Sync>, InterceptorError> {
        let (close_tx, close_rx) = watch::channel(false);
        let sender_ssrc = (Instant::now().elapsed().as_nanos() as u32) ^ 0x5A3C_19F1;
        Ok(Arc::new(FastTwccReceiver {
            interval: self.interval,
            start_time: Instant::now(),
            recorder: Arc::new(StdMutex::new(Recorder::new(sender_ssrc))),
            close_tx: StdMutex::new(Some(close_tx)),
            close_rx,
        }))
    }
}

struct FastTwccReceiver {
    interval: Duration,
    start_time: Instant,
    recorder: Arc<StdMutex<Recorder>>,
    close_tx: StdMutex<Option<watch::Sender<bool>>>,
    close_rx: watch::Receiver<bool>,
}

struct FastTwccStream {
    parent_reader: Arc<dyn RTPReader + Send + Sync>,
    hdr_ext_id: u8,
    ssrc: u32,
    start_time: Instant,
    recorder: Arc<StdMutex<Recorder>>,
}

#[async_trait]
impl RTPReader for FastTwccStream {
    async fn read(
        &self,
        buf: &mut [u8],
        attributes: &Attributes,
    ) -> Result<(rtp::packet::Packet, Attributes), InterceptorError> {
        let (pkt, attr) = self.parent_reader.read(buf, attributes).await?;

        if let Some(mut ext) = pkt.header.get_extension(self.hdr_ext_id) {
            if let Ok(tcc_ext) = TransportCcExtension::unmarshal(&mut ext) {
                let arrival_us = self.start_time.elapsed().as_micros() as i64;
                if let Ok(mut rec) = self.recorder.lock() {
                    rec.record(self.ssrc, tcc_ext.transport_sequence, arrival_us);
                }
            }
        }

        Ok((pkt, attr))
    }
}

#[async_trait]
impl Interceptor for FastTwccReceiver {
    async fn bind_rtcp_reader(
        &self,
        reader: Arc<dyn RTCPReader + Send + Sync>,
    ) -> Arc<dyn RTCPReader + Send + Sync> {
        reader
    }

    async fn bind_rtcp_writer(
        &self,
        writer: Arc<dyn RTCPWriter + Send + Sync>,
    ) -> Arc<dyn RTCPWriter + Send + Sync> {
        let recorder = Arc::clone(&self.recorder);
        let interval = self.interval;
        let mut close_rx = self.close_rx.clone();
        let writer_clone = Arc::clone(&writer);

        tokio::spawn(async move {
            let mut ticker = tokio::time::interval(interval);
            ticker.set_missed_tick_behavior(MissedTickBehavior::Skip);
            let attrs = Attributes::new();
            loop {
                tokio::select! {
                    _ = close_rx.changed() => {
                        if *close_rx.borrow() {
                            break;
                        }
                    }
                    _ = ticker.tick() => {
                        let pkts = match recorder.lock() {
                            Ok(mut rec) => rec.build_feedback_packet(),
                            Err(_) => Vec::new(),
                        };
                        if pkts.is_empty() {
                            continue;
                        }
                        if let Err(err) = writer_clone.write(&pkts, &attrs).await {
                            crate::nano_warn!("fast-twcc rtcp write error: {err}");
                        }
                    }
                }
            }
        });

        writer
    }

    async fn bind_local_stream(
        &self,
        _info: &StreamInfo,
        writer: Arc<dyn RTPWriter + Send + Sync>,
    ) -> Arc<dyn RTPWriter + Send + Sync> {
        writer
    }

    async fn unbind_local_stream(&self, _info: &StreamInfo) {}

    async fn bind_remote_stream(
        &self,
        info: &StreamInfo,
        reader: Arc<dyn RTPReader + Send + Sync>,
    ) -> Arc<dyn RTPReader + Send + Sync> {
        let mut hdr_ext_id = 0u8;
        for ext in &info.rtp_header_extensions {
            if ext.uri == TRANSPORT_CC_URI {
                hdr_ext_id = ext.id as u8;
                break;
            }
        }
        if hdr_ext_id == 0 {
            return reader;
        }

        Arc::new(FastTwccStream {
            parent_reader: reader,
            hdr_ext_id,
            ssrc: info.ssrc,
            start_time: self.start_time,
            recorder: Arc::clone(&self.recorder),
        })
    }

    async fn unbind_remote_stream(&self, _info: &StreamInfo) {}

    async fn close(&self) -> Result<(), InterceptorError> {
        if let Ok(mut guard) = self.close_tx.lock() {
            if let Some(tx) = guard.take() {
                let _ = tx.send(true);
            }
        }
        Ok(())
    }
}
