#!/usr/bin/env python3
"""Render XboxPad promotional PNG kit for GitHub & Xiaohongshu via headless Chrome."""

import argparse
import base64
import mimetypes
import os
import subprocess
import tempfile
from pathlib import Path

CHROME_BIN = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
REPO_ROOT = Path(__file__).resolve().parents[2]
APP_ICON_PATH = str(REPO_ROOT / "XboxPad/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
OUT_DIR = REPO_ROOT / "docs/promo"


def to_data_uri(path: str) -> str:
    mime, _ = mimetypes.guess_type(path)
    mime = mime or "image/png"
    with open(path, "rb") as f:
        b64 = base64.b64encode(f.read()).decode("ascii")
    return f"data:{mime};base64,{b64}"


BASE_CSS = """
* { box-sizing: border-box; margin: 0; padding: 0; }
html, body {
  width: 100%;
  height: 100%;
  overflow: hidden;
  background: #06090D;
  color: #F4F7FA;
  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "PingFang SC", "Hiragino Sans GB", "Helvetica Neue", sans-serif;
  -webkit-font-smoothing: antialiased;
  text-rendering: optimizeLegibility;
}
.canvas {
  position: relative;
  width: 100%;
  height: 100%;
  background: #06090D;
  overflow: hidden;
}
.bg-grid {
  position: absolute;
  inset: 0;
  background-image:
    linear-gradient(rgba(255,255,255,0.028) 1px, transparent 1px),
    linear-gradient(90deg, rgba(255,255,255,0.028) 1px, transparent 1px);
  background-size: 48px 48px;
  mask-image: radial-gradient(ellipse 85% 75% at 50% 45%, black 30%, transparent 100%);
  pointer-events: none;
}
.glow-emerald {
  position: absolute;
  border-radius: 50%;
  background: radial-gradient(circle, rgba(16, 214, 118, 0.24) 0%, rgba(16, 185, 129, 0.06) 45%, transparent 72%);
  filter: blur(18px);
  pointer-events: none;
}
.glow-cyan {
  position: absolute;
  border-radius: 50%;
  background: radial-gradient(circle, rgba(56, 189, 248, 0.16) 0%, rgba(14, 165, 233, 0.04) 50%, transparent 72%);
  filter: blur(22px);
  pointer-events: none;
}
.glow-amber {
  position: absolute;
  border-radius: 50%;
  background: radial-gradient(circle, rgba(245, 158, 11, 0.16) 0%, rgba(245, 158, 11, 0.03) 50%, transparent 72%);
  filter: blur(22px);
  pointer-events: none;
}
.text-emerald {
  background: linear-gradient(135deg, #4AF6A2 0%, #10D676 55%, #059669 100%);
  -webkit-background-clip: text;
  -webkit-text-fill-color: transparent;
}
.text-cyan {
  background: linear-gradient(135deg, #7DD3FC 0%, #38BDF8 60%, #0EA5E9 100%);
  -webkit-background-clip: text;
  -webkit-text-fill-color: transparent;
}
.text-gold {
  background: linear-gradient(135deg, #FDE68A 0%, #FBBF24 55%, #F59E0B 100%);
  -webkit-background-clip: text;
  -webkit-text-fill-color: transparent;
}
.card {
  background: linear-gradient(180deg, rgba(20, 29, 41, 0.88) 0%, rgba(12, 18, 26, 0.92) 100%);
  border: 1px solid rgba(255, 255, 255, 0.09);
  box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.08), 0 18px 40px rgba(0, 0, 0, 0.42);
  border-radius: 28px;
}
.pill {
  display: inline-flex;
  align-items: center;
  gap: 8px;
  padding: 9px 18px;
  border-radius: 999px;
  font-size: 18px;
  font-weight: 600;
  letter-spacing: 0.01em;
  background: rgba(16, 214, 118, 0.12);
  border: 1px solid rgba(34, 229, 132, 0.32);
  color: #6EE7B7;
}
.pill-neutral {
  background: rgba(255, 255, 255, 0.06);
  border: 1px solid rgba(255, 255, 255, 0.12);
  color: #D1DBE6;
}
.app-icon-squircle {
  border-radius: 22.5%;
  box-shadow: 0 14px 36px rgba(16, 214, 118, 0.28), 0 0 0 1px rgba(255,255,255,0.14);
}
.xhs-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 56px 64px 0 64px;
  position: relative;
  z-index: 3;
}
.brand-chip {
  display: flex;
  align-items: center;
  gap: 16px;
}
.brand-chip img {
  width: 54px;
  height: 54px;
  border-radius: 13px;
  box-shadow: 0 6px 18px rgba(16, 214, 118, 0.28);
}
.brand-chip .name {
  font-size: 28px;
  font-weight: 800;
  letter-spacing: -0.02em;
  color: #FFFFFF;
}
.brand-chip .sub {
  font-size: 16px;
  font-weight: 500;
  color: #8CA0B5;
  margin-top: 2px;
}
.page-badge {
  padding: 10px 20px;
  border-radius: 999px;
  background: rgba(255, 255, 255, 0.06);
  border: 1px solid rgba(255, 255, 255, 0.10);
  font-size: 20px;
  font-weight: 700;
  color: #9FB2C7;
  font-variant-numeric: tabular-nums;
}
.xhs-footer {
  position: absolute;
  left: 64px;
  right: 64px;
  bottom: 48px;
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding-top: 22px;
  border-top: 1px solid rgba(255, 255, 255, 0.08);
  color: #7D91A6;
  font-size: 20px;
  font-weight: 500;
  z-index: 3;
}
.xhs-footer .tag {
  color: #34D399;
  font-weight: 700;
}
.icon-box {
  width: 68px;
  height: 68px;
  border-radius: 20px;
  display: flex;
  align-items: center;
  justify-content: center;
  flex-shrink: 0;
}
"""


def svg_icon(kind: str, color: str = "#34D399", size: int = 34) -> str:
    paths = {
        "spark": '<path d="M12 2L14.8 8.6L22 9.2L16.5 13.9L18.2 21L12 17.2L5.8 21L7.5 13.9L2 9.2L9.2 8.6L12 2Z"/>',
        "bolt": '<path d="M13 2L4 14H11L10 22L20 10H13L13 2Z"/>',
        "sun": '<circle cx="12" cy="12" r="4"/><path d="M12 2v3M12 19v3M4.93 4.93l2.12 2.12M16.95 16.95l2.12 2.12M2 12h3M19 12h3M4.93 19.07l2.12-2.12M16.95 7.05l2.12-2.12"/>',
        "layers": '<path d="M12 2L2 7l10 5 10-5-10-5z"/><path d="M2 12l10 5 10-5"/><path d="M2 17l10 5 10-5"/>',
        "gamepad": '<rect x="2" y="6" width="20" height="12" rx="6"/><path d="M6 12h4M8 10v4"/><circle cx="15.5" cy="10.5" r="1"/><circle cx="17.5" cy="12.5" r="1"/>',
        "xbox": '<circle cx="12" cy="12" r="9.5"/><path d="M7.8 7.6c2.6 1.5 5.8 4.9 8.4 8.8M16.2 7.6c-2.6 1.5-5.8 4.9-8.4 8.8"/>',
        "keyboard": '<rect x="2" y="5" width="20" height="14" rx="3"/><path d="M6 9h.01M10 9h.01M14 9h.01M18 9h.01M6 13h.01M10 13h.01M14 13h.01M18 13h.01M8 16h8"/>',
        "vibrate": '<rect x="7" y="4" width="10" height="16" rx="2"/><path d="M3 8v8M21 8v8M1 10v4M23 10v4"/>',
        "cloud": '<path d="M17.5 19H7a5 5 0 0 1-.5-9.97A6.5 6.5 0 0 1 19 10.5a4 4 0 0 1-1.5 8.5z"/>',
        "mic": '<rect x="9" y="2" width="6" height="11" rx="3"/><path d="M5 10a7 7 0 0 0 14 0M12 17v5M8 22h8"/>',
        "tv": '<rect x="2" y="4" width="20" height="13" rx="2.5"/><path d="M8 21h8M12 17v4"/>',
        "sliders": '<path d="M4 6h16M4 12h16M4 18h16"/><circle cx="9" cy="6" r="2" fill="#06090D"/><circle cx="15" cy="12" r="2" fill="#06090D"/><circle cx="11" cy="18" r="2" fill="#06090D"/>',
        "check": '<path d="M20 6L9 17l-5-5"/>',
    }
    p = paths[kind]
    return f'<svg width="{size}" height="{size}" viewBox="0 0 24 24" fill="none" stroke="{color}" stroke-width="2.1" stroke-linecap="round" stroke-linejoin="round">{p}</svg>'


def wrap_doc(body: str, extra_css: str = "") -> str:
    return f"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8" />
<style>{BASE_CSS}\n{extra_css}</style>
</head>
<body>{body}</body>
</html>"""


def build_github_hero(icon_uri: str, hero_uri: str) -> str:
    extra_css = """
    .gh-wrap {
      display: flex;
      width: 100%;
      height: 100%;
      position: relative;
      z-index: 2;
      padding: 64px 72px;
      align-items: center;
      justify-content: space-between;
      gap: 44px;
    }
    .gh-left {
      width: 47%;
      display: flex;
      flex-direction: column;
      z-index: 3;
    }
    .gh-brand {
      display: flex;
      align-items: center;
      gap: 20px;
      margin-bottom: 28px;
    }
    .gh-brand img {
      width: 78px;
      height: 78px;
    }
    .gh-brand-title {
      font-size: 46px;
      font-weight: 850;
      letter-spacing: -0.03em;
      line-height: 1;
    }
    .gh-brand-ver {
      display: inline-block;
      margin-top: 8px;
      padding: 4px 12px;
      border-radius: 999px;
      background: rgba(16, 214, 118, 0.14);
      border: 1px solid rgba(34, 229, 132, 0.3);
      color: #6EE7B7;
      font-size: 14px;
      font-weight: 700;
      letter-spacing: 0.04em;
    }
    .gh-headline {
      font-size: 52px;
      font-weight: 850;
      line-height: 1.14;
      letter-spacing: -0.03em;
      margin-bottom: 20px;
    }
    .gh-desc {
      font-size: 22px;
      line-height: 1.55;
      color: #A2B4C7;
      margin-bottom: 34px;
      font-weight: 450;
    }
    .gh-pills {
      display: flex;
      flex-wrap: wrap;
      gap: 12px;
      margin-bottom: 34px;
    }
    .gh-pills .pill {
      font-size: 16px;
      padding: 9px 16px;
    }
    .gh-arch {
      display: flex;
      align-items: center;
      gap: 24px;
      padding-top: 22px;
      border-top: 1px solid rgba(255,255,255,0.09);
      color: #7D91A6;
      font-size: 16px;
      font-weight: 600;
    }
    .gh-arch span {
      display: inline-flex;
      align-items: center;
      gap: 8px;
    }
    .dot {
      width: 8px;
      height: 8px;
      border-radius: 50%;
      background: #10D676;
      box-shadow: 0 0 10px #10D676;
    }
    .gh-right {
      width: 53%;
      display: flex;
      flex-direction: column;
      gap: 16px;
      align-items: center;
      justify-content: center;
    }
    .hero-frame {
      width: 100%;
      aspect-ratio: 16 / 9;
      border-radius: 28px;
      overflow: hidden;
      position: relative;
      border: 1px solid rgba(255,255,255,0.12);
      box-shadow: 0 30px 76px rgba(0, 0, 0, 0.65), 0 0 60px rgba(16, 214, 118, 0.14);
      background: #05080C;
    }
    .hero-frame img {
      width: 100%;
      height: 100%;
      object-fit: cover;
      object-position: center;
      display: block;
    }
    .hero-vignette {
      position: absolute;
      inset: 0;
      background: radial-gradient(ellipse at center, transparent 62%, rgba(6, 9, 13, 0.45) 100%);
      pointer-events: none;
    }
    .float-badge {
      width: 100%;
      display: grid;
      grid-template-columns: repeat(4, 1fr);
      gap: 12px;
      padding: 18px 24px;
      border-radius: 22px;
      background: linear-gradient(180deg, rgba(20, 29, 41, 0.90) 0%, rgba(12, 18, 26, 0.94) 100%);
      border: 1px solid rgba(255,255,255,0.10);
      box-shadow: 0 16px 36px rgba(0,0,0,0.42);
    }
    .stat-cell {
      display: flex;
      flex-direction: column;
      gap: 2px;
    }
    .stat-val {
      font-size: 22px;
      font-weight: 800;
      color: #FFFFFF;
      letter-spacing: -0.02em;
    }
    .stat-lbl {
      font-size: 13px;
      color: #8CA0B5;
      font-weight: 600;
    }
    """
    body = f"""
    <div class="canvas">
      <div class="bg-grid"></div>
      <div class="glow-emerald" style="width:760px;height:760px;left:-140px;top:-180px;"></div>
      <div class="glow-cyan" style="width:680px;height:680px;right:-120px;bottom:-220px;"></div>
      <div class="gh-wrap">
        <div class="gh-left">
          <div class="gh-brand">
            <img class="app-icon-squircle" src="{icon_uri}" alt="XboxPad" />
            <div>
              <div class="gh-brand-title">XboxPad</div>
              <div class="gh-brand-ver">NATIVE IPADOS · SWIFT + METAL + RUST</div>
            </div>
          </div>
          <div class="gh-headline">
            让 iPad 成为你的<br/><span class="text-emerald">2K 120Hz Xbox 掌机</span>
          </div>
          <div class="gh-desc">
            纯原生 Xbox 本地串流（Remote Play）与 xCloud 云游戏客户端。<br/>
            零 WebView 套壳，直驱 Apple Silicon MetalFX、ProMotion 与 XDR HDR。
          </div>
          <div class="gh-pills">
            <span class="pill">2K 1440p 高码率</span>
            <span class="pill">MetalFX 硬件超分</span>
            <span class="pill">120Hz 双向光流补帧</span>
            <span class="pill">原生 EDR Auto-HDR</span>
            <span class="pill pill-neutral">真·西瓜键接管</span>
            <span class="pill pill-neutral">1–4P 多手柄 + 键鼠</span>
            <span class="pill pill-neutral">USB-C 外接屏 + 语音开麦</span>
          </div>
          <div class="gh-arch">
            <span><i class="dot"></i>Swift + Metal 渲染管线</span>
            <span><i class="dot"></i>Rust 原生 WebRTC 内核</span>
            <span><i class="dot"></i>Remote Play + xCloud</span>
          </div>
        </div>
        <div class="gh-right">
          <div class="hero-frame">
            <img src="{hero_uri}" alt="Hero" />
            <div class="hero-vignette"></div>
          </div>
          <div class="float-badge">
            <div class="stat-cell">
              <div class="stat-val text-emerald">1440p</div>
              <div class="stat-lbl">本地高码率</div>
            </div>
            <div class="stat-cell">
              <div class="stat-val text-cyan">120Hz</div>
              <div class="stat-lbl">光流补帧</div>
            </div>
            <div class="stat-cell">
              <div class="stat-val text-gold">EDR HDR</div>
              <div class="stat-lbl">直驱 XDR/OLED</div>
            </div>
            <div class="stat-cell">
              <div class="stat-val">1–4P</div>
              <div class="stat-lbl">多手柄+键鼠</div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
    return wrap_doc(body, extra_css)


COMPARE_ROWS = [
    ("底层架构", "原生 Swift + Metal + Rust", "浏览器 / WebRTC", "原生 iOS", "混合跨平台", "浏览器脚本"),
    ("本地串流最高画质", "2K 1440p + 高码率", "仅 1080p 低码率", "1080p", "1080p", "1080p"),
    ("MetalFX 硬件超分", "原生硬件级超分", "不支持", "不支持", "仅软件锐化", "仅 CSS 滤镜"),
    ("120Hz 光流补帧", "双向金字塔光流", "锁 60fps", "锁 60fps", "锁 60fps", "锁 60fps"),
    ("原生 EDR Auto-HDR", "3档调色 直驱 XDR", "不支持", "不支持", "不支持", "不支持"),
    ("xCloud 云游戏", "支持 + 日/韩/美切区", "需自行折腾代理", "不支持", "支持", "支持"),
    ("多手柄 + 型号电量", "1–4P + 型号与电量", "仅单手柄基础", "多手柄有限", "部分支持", "受浏览器限制"),
    ("外接鼠标键盘", "手柄模拟 + 原生双模式", "网页有限支持", "不支持", "支持", "桌面端优先"),
    ("实体西瓜键接管", "原生接管不跳系统", "经常误跳系统", "支持", "部分支持", "网页受限"),
    ("派对语音开麦", "48kHz Opus 上行", "支持", "有限/不稳定", "支持", "支持"),
    ("USB-C 外接屏全屏", "真 16:9 + 防烧屏", "仅镜像黑边", "仅镜像", "仅镜像", "仅镜像"),
    ("费用与广告", "免费 · 无广告订阅", "免费", "买断约 $15", "买断约 $7", "免费开源"),
]


def cell_class(val: str) -> str:
    if any(k in val for k in ("不支持", "锁 60", "黑边", "误跳", "折腾", "低码率")):
        return "c-no"
    if any(k in val for k in ("有限", "部分", "软件", "CSS", "镜像", "受限", "买断", "付费", "仅单", "不稳定")):
        return "c-mid"
    return "c-ok"


def build_github_compare(icon_uri: str) -> str:
    extra_css = """
    .wrap {
      position: relative;
      z-index: 2;
      padding: 48px 64px 44px 64px;
      height: 100%;
      display: flex;
      flex-direction: column;
    }
    .top {
      display: flex;
      align-items: center;
      justify-content: space-between;
      margin-bottom: 28px;
    }
    .title-group {
      display: flex;
      align-items: center;
      gap: 20px;
    }
    .title-group img {
      width: 60px;
      height: 60px;
      border-radius: 15px;
    }
    .title {
      font-size: 38px;
      font-weight: 850;
      letter-spacing: -0.025em;
    }
    .subtitle {
      font-size: 18px;
      color: #8CA0B5;
      margin-top: 4px;
    }
    .table-card {
      flex: 1;
      border-radius: 26px;
      overflow: hidden;
      border: 1px solid rgba(255,255,255,0.10);
      background: rgba(13, 19, 28, 0.92);
      box-shadow: 0 24px 60px rgba(0,0,0,0.5);
    }
    table {
      width: 100%;
      height: 100%;
      border-collapse: collapse;
      table-layout: fixed;
    }
    th, td {
      padding: 0 18px;
      text-align: left;
      border-bottom: 1px solid rgba(255,255,255,0.06);
      font-size: 17px;
      vertical-align: middle;
    }
    tr:last-child td { border-bottom: none; }
    thead th {
      height: 64px;
      font-size: 18px;
      font-weight: 800;
      background: rgba(255,255,255,0.03);
      color: #CBD5E1;
    }
    th.col-feat { width: 17%; color: #94A3B8; }
    th.col-us, td.col-us {
      width: 23%;
      background: linear-gradient(180deg, rgba(16, 214, 118, 0.14) 0%, rgba(16, 185, 129, 0.08) 100%);
      border-left: 1px solid rgba(34, 229, 132, 0.28);
      border-right: 1px solid rgba(34, 229, 132, 0.28);
    }
    thead th.col-us {
      background: linear-gradient(180deg, rgba(16, 214, 118, 0.28) 0%, rgba(16, 185, 129, 0.16) 100%);
      color: #6EE7B7;
      font-size: 20px;
    }
    td.col-feat {
      font-weight: 700;
      color: #E2E8F0;
    }
    td.col-us {
      font-weight: 750;
      color: #ECFDF5;
    }
    .us-badge {
      display: inline-flex;
      align-items: center;
      gap: 8px;
    }
    .us-dot {
      width: 9px;
      height: 9px;
      border-radius: 50%;
      background: #22E584;
      flex-shrink: 0;
      box-shadow: 0 0 8px rgba(34, 229, 132, 0.8);
    }
    .c-ok { color: #CBD5E1; font-weight: 550; }
    .c-mid { color: #FCD34D; font-weight: 550; opacity: 0.9; }
    .c-no { color: #64748B; font-weight: 500; }
    """
    rows_html = []
    for feat, us, official, onecast, xbplay, better in COMPARE_ROWS:
        rows_html.append(f"""
        <tr>
          <td class="col-feat">{feat}</td>
          <td class="col-us"><span class="us-badge"><i class="us-dot"></i>{us}</span></td>
          <td class="{cell_class(official)}">{official}</td>
          <td class="{cell_class(onecast)}">{onecast}</td>
          <td class="{cell_class(xbplay)}">{xbplay}</td>
          <td class="{cell_class(better)}">{better}</td>
        </tr>
        """)
    body = f"""
    <div class="canvas">
      <div class="bg-grid"></div>
      <div class="glow-emerald" style="width:700px;height:700px;left:18%;top:-240px;"></div>
      <div class="glow-cyan" style="width:600px;height:600px;right:-160px;bottom:-220px;"></div>
      <div class="wrap">
        <div class="top">
          <div class="title-group">
            <img class="app-icon-squircle" src="{icon_uri}" alt="XboxPad" />
            <div>
              <div class="title">XboxPad <span class="text-emerald">全方位能力对比</span></div>
              <div class="subtitle">原生 Swift + Metal + Rust 架构 vs 主流 iPadOS Xbox 串流与云游戏方案</div>
            </div>
          </div>
          <span class="pill">v1.0.32 · SideStore OTA</span>
        </div>
        <div class="table-card">
          <table>
            <thead>
              <tr>
                <th class="col-feat">功能维度</th>
                <th class="col-us">★ XboxPad（本 App）</th>
                <th>Xbox 官方网页</th>
                <th>OneCast</th>
                <th>XBPlay</th>
                <th>Better xCloud</th>
              </tr>
            </thead>
            <tbody>
              {''.join(rows_html)}
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
    return wrap_doc(body, extra_css)


def build_xhs_cover(icon_uri: str, hero_uri: str) -> str:
    extra_css = """
    .cover-body {
      position: relative;
      z-index: 2;
      padding: 36px 64px 0 64px;
      display: flex;
      flex-direction: column;
    }
    .kicker {
      display: inline-flex;
      align-items: center;
      gap: 10px;
      align-self: flex-start;
      padding: 11px 22px;
      border-radius: 999px;
      background: rgba(16, 214, 118, 0.14);
      border: 1px solid rgba(34, 229, 132, 0.36);
      color: #6EE7B7;
      font-size: 23px;
      font-weight: 750;
      margin-bottom: 26px;
    }
    .big-title {
      font-size: 86px;
      font-weight: 900;
      line-height: 1.12;
      letter-spacing: -0.035em;
      margin-bottom: 22px;
    }
    .sub-title {
      font-size: 31px;
      line-height: 1.48;
      color: #A7B9CC;
      font-weight: 500;
      margin-bottom: 34px;
    }
    .hero-box {
      width: 100%;
      height: 670px;
      border-radius: 38px;
      overflow: hidden;
      position: relative;
      border: 1.5px solid rgba(255,255,255,0.13);
      box-shadow: 0 36px 90px rgba(0,0,0,0.68), 0 0 80px rgba(16, 214, 118, 0.18);
      margin-bottom: 34px;
    }
    .hero-box img {
      width: 100%;
      height: 100%;
      object-fit: cover;
      object-position: center;
    }
    .hero-grad {
      position: absolute;
      inset: 0;
      background: linear-gradient(180deg, rgba(6,9,13,0.08) 0%, transparent 45%, rgba(6,9,13,0.78) 100%);
    }
    .hero-overlay-strip {
      position: absolute;
      left: 28px;
      right: 28px;
      bottom: 26px;
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 20px 26px;
      border-radius: 24px;
      background: rgba(10, 15, 22, 0.78);
      backdrop-filter: blur(20px);
      border: 1px solid rgba(255,255,255,0.14);
    }
    .ov-item {
      display: flex;
      flex-direction: column;
      align-items: center;
      flex: 1;
    }
    .ov-item + .ov-item {
      border-left: 1px solid rgba(255,255,255,0.10);
    }
    .ov-num {
      font-size: 32px;
      font-weight: 850;
      letter-spacing: -0.02em;
    }
    .ov-txt {
      font-size: 18px;
      color: #9FB2C7;
      font-weight: 600;
      margin-top: 4px;
    }
    .bottom-chips {
      display: grid;
      grid-template-columns: repeat(3, 1fr);
      gap: 18px;
    }
    .b-chip {
      padding: 22px 20px;
      border-radius: 24px;
      background: rgba(17, 25, 36, 0.88);
      border: 1px solid rgba(255,255,255,0.09);
      text-align: center;
    }
    .b-chip-title {
      font-size: 25px;
      font-weight: 800;
      color: #FFFFFF;
      margin-bottom: 6px;
    }
    .b-chip-sub {
      font-size: 18px;
      color: #8CA0B5;
      font-weight: 500;
    }
    """
    body = f"""
    <div class="canvas">
      <div class="bg-grid"></div>
      <div class="glow-emerald" style="width:820px;height:820px;left:-180px;top:-220px;"></div>
      <div class="glow-cyan" style="width:760px;height:760px;right:-200px;bottom:80px;"></div>
      <div class="xhs-header">
        <div class="brand-chip">
          <img src="{icon_uri}" alt="XboxPad" />
          <div>
            <div class="name">XboxPad</div>
            <div class="sub">原生 Swift + Metal + Rust</div>
          </div>
        </div>
        <div class="page-badge">01 / 05</div>
      </div>
      <div class="cover-body">
        <div class="kicker">★ 专为 iPad Pro 打造的 Xbox 串流神器</div>
        <div class="big-title">
          把 iPad 变成<br/><span class="text-emerald">2K 120Hz</span> Xbox 掌机
        </div>
        <div class="sub-title">
          零浏览器套壳！本地高码率 + xCloud 云游戏全能打，<br/>画质、帧率、西瓜键、外接屏一次拉满。
        </div>
        <div class="hero-box">
          <img src="{hero_uri}" alt="iPad Pro and Xbox Controller" />
          <div class="hero-grad"></div>
          <div class="hero-overlay-strip">
            <div class="ov-item">
              <div class="ov-num text-emerald">2K 1440p</div>
              <div class="ov-txt">突破官方限制</div>
            </div>
            <div class="ov-item">
              <div class="ov-num text-cyan">120Hz</div>
              <div class="ov-txt">光流补帧</div>
            </div>
            <div class="ov-item">
              <div class="ov-num text-gold">Auto-HDR</div>
              <div class="ov-txt">直驱 XDR/OLED</div>
            </div>
          </div>
        </div>
        <div class="bottom-chips">
          <div class="b-chip">
            <div class="b-chip-title">真·西瓜键</div>
            <div class="b-chip-sub">不再误跳系统</div>
          </div>
          <div class="b-chip">
            <div class="b-chip-title">1–4P + 键鼠</div>
            <div class="b-chip-sub">多手柄型号电量</div>
          </div>
          <div class="b-chip">
            <div class="b-chip-title">云游戏 + 投屏</div>
            <div class="b-chip-sub">开麦/外接屏全齐</div>
          </div>
        </div>
      </div>
      <div class="xhs-footer">
        <span>左滑看核心黑科技与横评对比 →</span>
        <span class="tag">#Xbox串流 #iPadPro #xCloud</span>
      </div>
    </div>
    """
    return wrap_doc(body, extra_css)


def build_xhs_feature_card(
    icon_uri: str,
    page_str: str,
    kicker: str,
    title_l1: str,
    title_em: str,
    title_grad: str,
    subtitle: str,
    cards: list,
    summary_text: str,
    summary_chip: str,
    footer_left: str,
    glow_style: str,
) -> str:
    extra_css = """
    .section-body {
      position: relative;
      z-index: 2;
      padding: 40px 64px 0 64px;
    }
    .kicker {
      display: inline-flex;
      padding: 10px 22px;
      border-radius: 999px;
      background: rgba(255,255,255,0.06);
      border: 1px solid rgba(255,255,255,0.12);
      font-size: 22px;
      font-weight: 700;
      color: #A7B9CC;
      margin-bottom: 22px;
    }
    .sec-title {
      font-size: 70px;
      font-weight: 900;
      line-height: 1.14;
      letter-spacing: -0.03em;
      margin-bottom: 18px;
    }
    .sec-sub {
      font-size: 27px;
      line-height: 1.48;
      color: #93A7BC;
      margin-bottom: 38px;
    }
    .bento-stack {
      display: flex;
      flex-direction: column;
      gap: 28px;
    }
    .feat-card {
      padding: 36px 36px;
      display: flex;
      align-items: flex-start;
      gap: 26px;
      position: relative;
      overflow: hidden;
    }
    .feat-accent-bar {
      position: absolute;
      left: 0;
      top: 28px;
      bottom: 28px;
      width: 5px;
      border-radius: 0 6px 6px 0;
    }
    .feat-content {
      flex: 1;
    }
    .feat-top {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 16px;
      margin-bottom: 12px;
    }
    .feat-title {
      font-size: 33px;
      font-weight: 850;
      color: #FFFFFF;
      letter-spacing: -0.02em;
    }
    .feat-badge {
      padding: 6px 14px;
      border-radius: 999px;
      font-size: 17px;
      font-weight: 750;
      white-space: nowrap;
    }
    .feat-desc {
      font-size: 23px;
      line-height: 1.54;
      color: #A5B7C9;
      font-weight: 450;
    }
    .summary-bar {
      margin-top: 28px;
      padding: 24px 30px;
      border-radius: 24px;
      background: linear-gradient(135deg, rgba(16, 214, 118, 0.12) 0%, rgba(56, 189, 248, 0.08) 100%);
      border: 1px solid rgba(255,255,255,0.10);
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 20px;
    }
    .summary-text {
      font-size: 22px;
      font-weight: 700;
      color: #E2E8F0;
    }
    .summary-chip {
      padding: 8px 18px;
      border-radius: 999px;
      background: rgba(16, 214, 118, 0.16);
      border: 1px solid rgba(34, 229, 132, 0.34);
      color: #6EE7B7;
      font-size: 18px;
      font-weight: 750;
      white-space: nowrap;
    }
    """
    cards_html = []
    for c in cards:
        cards_html.append(f"""
        <div class="card feat-card">
          <div class="feat-accent-bar" style="background:{c['accent']};"></div>
          <div class="icon-box" style="background:{c['bg']}; border: 1px solid {c['border']};">
            {svg_icon(c['icon'], c['accent'], 34)}
          </div>
          <div class="feat-content">
            <div class="feat-top">
              <div class="feat-title">{c['title']}</div>
              <div class="feat-badge" style="background:{c['bg']};color:{c['accent']};border:1px solid {c['border']};">{c['badge']}</div>
            </div>
            <div class="feat-desc">{c['desc']}</div>
          </div>
        </div>
        """)
    body = f"""
    <div class="canvas">
      <div class="bg-grid"></div>
      {glow_style}
      <div class="xhs-header">
        <div class="brand-chip">
          <img src="{icon_uri}" alt="XboxPad" />
          <div>
            <div class="name">XboxPad</div>
            <div class="sub">Native Xbox Streaming for iPadOS</div>
          </div>
        </div>
        <div class="page-badge">{page_str}</div>
      </div>
      <div class="section-body">
        <div class="kicker">{kicker}</div>
        <div class="sec-title">{title_l1}<br/><span class="{title_grad}">{title_em}</span></div>
        <div class="sec-sub">{subtitle}</div>
        <div class="bento-stack">
          {''.join(cards_html)}
        </div>
        <div class="summary-bar">
          <div class="summary-text">{summary_text}</div>
          <div class="summary-chip">{summary_chip}</div>
        </div>
      </div>
      <div class="xhs-footer">
        <span>{footer_left}</span>
        <span class="tag">XboxPad · v1.0.32</span>
      </div>
    </div>
    """
    return wrap_doc(body, extra_css)


def build_xhs_compare(icon_uri: str) -> str:
    extra_css = """
    .cmp-body {
      position: relative;
      z-index: 2;
      padding: 34px 52px 0 52px;
    }
    .sec-title {
      font-size: 62px;
      font-weight: 900;
      line-height: 1.15;
      letter-spacing: -0.03em;
      margin-bottom: 12px;
    }
    .sec-sub {
      font-size: 24px;
      color: #93A7BC;
      margin-bottom: 26px;
    }
    .t-card {
      border-radius: 26px;
      overflow: hidden;
      border: 1px solid rgba(255,255,255,0.10);
      background: rgba(13, 19, 28, 0.94);
      box-shadow: 0 24px 60px rgba(0,0,0,0.52);
    }
    table {
      width: 100%;
      border-collapse: collapse;
      table-layout: fixed;
    }
    th, td {
      padding: 20px 12px;
      text-align: left;
      border-bottom: 1px solid rgba(255,255,255,0.06);
      font-size: 20px;
      line-height: 1.25;
      vertical-align: middle;
    }
    tr:last-child td { border-bottom: none; }
    thead th {
      padding: 23px 12px;
      font-size: 21px;
      font-weight: 850;
      background: rgba(255,255,255,0.04);
      color: #CBD5E1;
    }
    th.c-f, td.c-f { width: 20%; font-weight: 750; color: #E2E8F0; padding-left: 18px; }
    th.c-us, td.c-us {
      width: 26%;
      background: rgba(16, 214, 118, 0.13);
      border-left: 1px solid rgba(34, 229, 132, 0.30);
      border-right: 1px solid rgba(34, 229, 132, 0.30);
      color: #ECFDF5;
      font-weight: 800;
    }
    thead th.c-us {
      background: rgba(16, 214, 118, 0.28);
      color: #6EE7B7;
      font-size: 21px;
    }
    .c-ok { color: #CBD5E1; font-weight: 550; }
    .c-mid { color: #FCD34D; font-weight: 550; }
    .c-no { color: #64748B; font-weight: 500; }
    .cta-box {
      margin-top: 24px;
      padding: 24px 28px;
      border-radius: 24px;
      background: linear-gradient(135deg, rgba(16, 214, 118, 0.16) 0%, rgba(14, 165, 233, 0.12) 100%);
      border: 1px solid rgba(34, 229, 132, 0.32);
      display: flex;
      align-items: center;
      justify-content: space-between;
    }
    .cta-main {
      font-size: 26px;
      font-weight: 850;
      color: #FFFFFF;
    }
    .cta-sub {
      font-size: 19px;
      color: #A7F3D0;
      margin-top: 5px;
      font-weight: 500;
    }
    .cta-pill {
      padding: 12px 22px;
      border-radius: 999px;
      background: #10D676;
      color: #04130B;
      font-size: 21px;
      font-weight: 850;
      white-space: nowrap;
    }
    """
    short_rows = [
        ("底层架构", "原生 Swift+Metal+Rust", "网页 WebRTC", "原生 iOS", "跨平台壳"),
        ("本地最高画质", "2K 1440p 高码率", "1080p 低码率", "1080p", "1080p"),
        ("MetalFX 超分", "✓ 硬件级超分", "✗ 不支持", "✗ 不支持", "软件锐化"),
        ("120Hz 补帧", "✓ 双向光流补帧", "✗ 锁 60fps", "✗ 锁 60fps", "✗ 锁 60fps"),
        ("原生 HDR 调色", "✓ EDR 直驱 XDR", "✗ 不支持", "✗ 不支持", "✗ 不支持"),
        ("xCloud 云游戏", "✓ 内置日/韩/美切区", "需折腾代理", "✗ 不支持", "✓ 支持"),
        ("多手柄+型号", "✓ 1–4P + 电量型号", "仅单手柄", "多手柄有限", "部分支持"),
        ("外接键鼠", "✓ 模拟 + 原生双模", "网页有限", "✗ 不支持", "✓ 支持"),
        ("实体西瓜键", "✓ 原生接管不跳系统", "经常误跳", "✓ 支持", "部分支持"),
        ("语音开麦", "✓ 48kHz Opus", "✓ 支持", "不稳定", "✓ 支持"),
        ("外接屏全屏", "✓ 真16:9 + 防烧屏", "镜像带黑边", "仅镜像", "仅镜像"),
        ("费用模式", "免费 · 无广告订阅", "免费", "付费 ~$15", "付费 ~$7"),
    ]
    tr_html = []
    for feat, us, off, oc, xb in short_rows:
        tr_html.append(f"""
        <tr>
          <td class="c-f">{feat}</td>
          <td class="c-us">{us}</td>
          <td class="{cell_class(off)}">{off}</td>
          <td class="{cell_class(oc)}">{oc}</td>
          <td class="{cell_class(xb)}">{xb}</td>
        </tr>
        """)
    body = f"""
    <div class="canvas">
      <div class="bg-grid"></div>
      <div class="glow-emerald" style="width:740px;height:740px;left:120px;top:-220px;"></div>
      <div class="glow-cyan" style="width:620px;height:620px;right:-160px;bottom:80px;"></div>
      <div class="xhs-header">
        <div class="brand-chip">
          <img src="{icon_uri}" alt="XboxPad" />
          <div>
            <div class="name">XboxPad</div>
            <div class="sub">横向实测对比 · 建议收藏</div>
          </div>
        </div>
        <div class="page-badge">05 / 05</div>
      </div>
      <div class="cmp-body">
        <div class="sec-title">一张图看懂：<span class="text-emerald">为什么换 XboxPad</span></div>
        <div class="sec-sub">对比 Xbox 官方网页、OneCast（$15）、XBPlay（$7）</div>
        <div class="t-card">
          <table>
            <thead>
              <tr>
                <th class="c-f">项目</th>
                <th class="c-us">★ XboxPad</th>
                <th>官方网页</th>
                <th>OneCast</th>
                <th>XBPlay</th>
              </tr>
            </thead>
            <tbody>
              {''.join(tr_html)}
            </tbody>
          </table>
        </div>
        <div class="cta-box">
          <div>
            <div class="cta-main">开源级体验 · SideStore 一键 OTA 更新</div>
            <div class="cta-sub">iPad Pro / Air / mini 全系支持 · 吃满苹果硬件生态</div>
          </div>
          <div class="cta-pill">收藏备用 ★</div>
        </div>
      </div>
      <div class="xhs-footer">
        <span>欢迎评论区交流想加的新功能</span>
        <span class="tag">#XboxPad #iPad串流 #游戏外设</span>
      </div>
    </div>
    """
    return wrap_doc(body, extra_css)


def render_html_to_png(html: str, out_path: Path, width: int, height: int, scale: int = 1) -> None:
    with tempfile.NamedTemporaryFile("w", suffix=".html", delete=False, encoding="utf-8") as tf:
        tf.write(html)
        html_path = tf.name
    try:
        cmd = [
            CHROME_BIN,
            "--headless=new",
            "--disable-gpu",
            "--hide-scrollbars",
            f"--window-size={width},{height}",
            f"--force-device-scale-factor={scale}",
            "--virtual-time-budget=1500",
            f"--screenshot={out_path}",
            f"file://{html_path}",
        ]
        subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    finally:
        if os.path.exists(html_path):
            os.unlink(html_path)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--hero", required=True, help="Path to hero product image")
    args = parser.parse_args()

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    icon_uri = to_data_uri(APP_ICON_PATH)
    hero_uri = to_data_uri(args.hero)

    graphics_cards = [
        {
            "icon": "layers",
            "title": "本地串流 2K 1440p 高码率",
            "badge": "突破官方 1080p",
            "accent": "#22E584",
            "bg": "rgba(16, 214, 118, 0.14)",
            "border": "rgba(34, 229, 132, 0.30)",
            "desc": "采用高码率串流档位，画面锐度与暗部细节远超官方网页端，告别糊成马赛克。",
        },
        {
            "icon": "spark",
            "title": "Apple MetalFX 硬件空间超分",
            "badge": "Apple Silicon 原生",
            "accent": "#38BDF8",
            "bg": "rgba(56, 189, 248, 0.14)",
            "border": "rgba(56, 189, 248, 0.32)",
            "desc": "直接调用苹果硬件级 MTLFXSpatialScaler，低带宽环境或 1080p 云游戏也能输出清脆纹理。",
        },
        {
            "icon": "bolt",
            "title": "120Hz 双向光流补帧",
            "badge": "ProMotion 满血",
            "accent": "#A78BFA",
            "bg": "rgba(167, 139, 250, 0.14)",
            "border": "rgba(167, 139, 250, 0.32)",
            "desc": "自研 Metal 金字塔双向光流 + 遮挡防伪影保护，把 Xbox 60fps 丝滑插帧到 120Hz。",
        },
        {
            "icon": "sun",
            "title": "原生 EDR Auto-HDR + 暗场去色带",
            "badge": "自然 / 鲜艳 / 影院",
            "accent": "#FBBF24",
            "bg": "rgba(251, 191, 36, 0.14)",
            "border": "rgba(251, 191, 36, 0.32)",
            "desc": "直驱 iPad Pro XDR/OLED 峰值亮度，8-bit 暗部去色带，并内置机身温控自动降档保护。",
        },
    ]

    controls_cards = [
        {
            "icon": "xbox",
            "title": "真·实体西瓜键（Xbox Home）接管",
            "badge": "告别误跳系统",
            "accent": "#22E584",
            "bg": "rgba(16, 214, 118, 0.14)",
            "border": "rgba(34, 229, 132, 0.30)",
            "desc": "原生 GameController 接管，按西瓜键直接呼出 Xbox 菜单，不再误跳 Apple Games。",
        },
        {
            "icon": "gamepad",
            "title": "1–4P 多手柄同玩 + 型号与电量识别",
            "badge": "全平台手柄通吃",
            "accent": "#38BDF8",
            "bg": "rgba(56, 189, 248, 0.14)",
            "border": "rgba(56, 189, 248, 0.32)",
            "desc": "支持 4 人本地同玩，自动识别 Xbox / Elite 2 / PS5 / Switch Pro 型号及电量。",
        },
        {
            "icon": "keyboard",
            "title": "外接鼠标 & 键盘双模式",
            "badge": "支持指针锁定",
            "accent": "#A78BFA",
            "bg": "rgba(167, 139, 250, 0.14)",
            "border": "rgba(167, 139, 250, 0.32)",
            "desc": "提供「手柄模拟（100% 游戏兼容）」与「原生 Xbox 键鼠」双模式，秒变便携游戏本。",
        },
        {
            "icon": "vibrate",
            "title": "扳机/握把双震动 + 陀螺仪体感 + 触控手柄",
            "badge": "深度微调",
            "accent": "#FBBF24",
            "bg": "rgba(251, 191, 36, 0.14)",
            "border": "rgba(251, 191, 36, 0.32)",
            "desc": "CoreHaptics 扳机震动、独立摇杆死区与曲线、陀螺仪体感瞄准及多点触控手柄。",
        },
    ]

    eco_cards = [
        {
            "icon": "cloud",
            "title": "xCloud 云游戏免折腾 · 一键切区",
            "badge": "日 / 韩 / 美节点",
            "accent": "#38BDF8",
            "bg": "rgba(56, 189, 248, 0.14)",
            "border": "rgba(56, 189, 248, 0.32)",
            "desc": "内置地区回退与日/韩/美节点一键切换，彻底解决非支持区无法进入云游戏的痛点。",
        },
        {
            "icon": "mic",
            "title": "原生 48kHz Opus 语音开麦",
            "badge": "派对直接沟通",
            "accent": "#22E584",
            "bg": "rgba(16, 214, 118, 0.14)",
            "border": "rgba(34, 229, 132, 0.30)",
            "desc": "通过 AudioToolbox 原生编码 Opus 音频上行，连麦开黑不用再单独挂手机或切耳机。",
        },
        {
            "icon": "tv",
            "title": "USB-C / HDMI 外接显示器真 16:9 全屏",
            "badge": "OLED 息屏防烧屏",
            "accent": "#FBBF24",
            "bg": "rgba(251, 191, 36, 0.14)",
            "border": "rgba(251, 191, 36, 0.32)",
            "desc": "独立外接屏场景无黑边满屏输出，自带 iPad 息屏防烧屏遮罩，并支持 AirPlay 投屏。",
        },
        {
            "icon": "sliders",
            "title": "极简悬浮栏 + 无损截屏 + 30s 延迟 HUD",
            "badge": "顺手不遮挡",
            "accent": "#A78BFA",
            "bg": "rgba(167, 139, 250, 0.14)",
            "border": "rgba(167, 139, 250, 0.32)",
            "desc": "轻点画面空白即刻收起控制栏；内置原画截屏存相册、实时延迟曲线与一键刷新画面。",
        },
    ]

    jobs = [
        ("github-hero-banner.png", 1600, 800, 1, build_github_hero(icon_uri, hero_uri)),
        ("github-compare-matrix.png", 1600, 980, 1, build_github_compare(icon_uri)),
        ("xhs-01-cover.png", 1242, 1656, 1, build_xhs_cover(icon_uri, hero_uri)),
        (
            "xhs-02-graphics.png",
            1242,
            1656,
            1,
            build_xhs_feature_card(
                icon_uri,
                "02 / 05",
                "GRAPHICS ENGINE · 画质拉满",
                "吃透 iPad Pro 屏幕的",
                "原生 Metal 画质引擎",
                "text-emerald",
                "从解码、超分、补帧到 HDR 调色，全链路 GPU 硬件加速。",
                graphics_cards,
                "纯原生 Metal 着色器渲染，低发热高能效",
                "零 WebView 套壳",
                "告别网页端 1080p 糊屏与 60Hz 卡顿",
                '<div class="glow-emerald" style="width:760px;height:760px;right:-180px;top:-200px;"></div><div class="glow-amber" style="width:620px;height:620px;left:-160px;bottom:80px;"></div>',
            ),
        ),
        (
            "xhs-03-controls.png",
            1242,
            1656,
            1,
            build_xhs_feature_card(
                icon_uri,
                "03 / 05",
                "PRO CONTROLS · 操控天花板",
                "手柄、键鼠、西瓜键",
                "全链路主机级接管",
                "text-cyan",
                "单人精调手感到四人本地同玩，外设支持直接一步到位。",
                controls_cards,
                "支持蓝牙 / 有线手柄与妙控键盘即插即用",
                "低延迟 Rust 输入",
                "iPadOS 游戏手柄原生底层接管",
                '<div class="glow-cyan" style="width:780px;height:780px;left:-180px;top:-180px;"></div><div class="glow-emerald" style="width:660px;height:660px;right:-160px;bottom:80px;"></div>',
            ),
        ),
        (
            "xhs-04-ecosystem.png",
            1242,
            1656,
            1,
            build_xhs_feature_card(
                icon_uri,
                "04 / 05",
                "FULL ECOSYSTEM · 全能体验",
                "不止本地串流：",
                "云游戏 / 开麦 / 外接屏全齐",
                "text-gold",
                "客厅接电视、出门玩云游戏、联机开语音，一个 App 全部搞定。",
                eco_cards,
                "支持 SideStore 自签源一键 OTA 升级更新",
                "免费 · 无广告",
                "本地 Remote Play + xCloud 云端双栖",
                '<div class="glow-amber" style="width:740px;height:740px;right:-160px;top:-180px;"></div><div class="glow-cyan" style="width:680px;height:680px;left:-160px;bottom:90px;"></div>',
            ),
        ),
        ("xhs-05-compare.png", 1242, 1656, 1, build_xhs_compare(icon_uri)),
    ]

    for filename, w, h, scale, html in jobs:
        out = OUT_DIR / filename
        render_html_to_png(html, out, w, h, scale)
        print(f"Rendered {out} ({w*scale}x{h*scale})")


if __name__ == "__main__":
    main()
