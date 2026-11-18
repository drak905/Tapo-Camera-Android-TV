"""Merge the lane specs into specs/android_tv_port_spec.json (Barrier 1).

Usage: python tools/merge_specs.py          # write the merged file
       python tools/merge_specs.py --check  # fail if it is out of date
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LANES = [
    "hybrid_control_spec.json",
    "media3_player_bridge_spec.json",
    "tv_ui_remote_spec.json",
    "tv_vod_onvif_spec.json",
]
OUT = ROOT / "specs" / "android_tv_port_spec.json"

# Barrier 1 answers to the lanes' open questions (owner may override).
DECISIONS = [
    "Local plane = TDP + secure v3 / legacy MD5 / TPAP SPAKE2+ (LAT aware) on :443 and :8800 media; RTSP/ONVIF only with an optional per-camera camera account.",
    "Remote/shared cameras: cloud passthrough for control, cloud relay (cloudType 2) for live and VOD.",
    "Cloud password: not stored by default. Opt-in 'Remember password on this TV' stores it in Keystore-backed secure storage (needed for v3/TPAP password login and captchaLogin refresh). LAT cameras work without it.",
    "Session/cloud tokens move from plain shared_preferences to flutter_secure_storage.",
    "Every byte source reaches ExoPlayer as plain MPEG-TS on the 127.0.0.1 RelayBridge with a per-launch key; JSON/audio/bad-HMAC parts are never forwarded.",
    "Audio: P0 video only. Later: Dart TS audio tap decodes G.711 A-law to PCM16 and plays it via a native AudioTrack for the focused camera, muted by default.",
    "Per-camera limit of 2 media sessions; limit errors are fatal (no retry). StreamQueue keeps one connecting stream at a time.",
    "Motion alerts without a camera account: poll getLastAlarmInfo every 5 s locally, every 30 s through passthrough; toast only (no live PiP, it would use a media session). ONVIF PullPoint only with a camera account.",
    "Recordings open from a button in the live-view controls; speed menu inside the recordings player (OK shows controls).",
    "Max remote streams: 1..8, default 4. Grid stays at most 3x3 on TV. The All-cameras grid follows the chosen sort order.",
    "Camera account is per camera, as on Windows.",
    "services-sync: use the thing's appServerUrlV2 with /v1 path like Windows; keep v2->v1 fallback harmless.",
    "Crypto first in pure Dart (package:pointycastle / cryptography); move to Kotlin only if a Tier 4 measurement on a real TV box shows it is too slow.",
]


def build():
    merged = {"name": "android_tv_port_spec", "lanes": {}, "items": [], "decisions": DECISIONS, "open_questions": []}
    seen = set()
    for name in LANES:
        lane = json.loads((ROOT / "specs" / name).read_text(encoding="utf-8"))
        lane_id = lane.get("lane", name)
        merged["lanes"][lane_id] = {"file": f"specs/{name}", "items": len(lane["items"]),
                                    "decisions": lane.get("decisions", [])}
        for item in lane["items"]:
            if item["id"] in seen:
                raise SystemExit(f"duplicate id {item['id']}")
            seen.add(item["id"])
            merged["items"].append({**item, "lane": lane_id})
        for q in lane.get("open_questions", []):
            merged["open_questions"].append({"lane": lane_id, "question": q})
    return json.dumps(merged, indent=2, ensure_ascii=False) + "\n"


def main():
    text = build()
    if "--check" in sys.argv:
        if not OUT.exists() or OUT.read_text(encoding="utf-8") != text:
            raise SystemExit("android_tv_port_spec.json is out of date: run python tools/merge_specs.py")
        print("spec merge up to date")
        return
    OUT.write_bytes(text.encode("utf-8"))
    print(f"wrote {OUT} ({text.count(chr(10))} lines)")


if __name__ == "__main__":
    main()
