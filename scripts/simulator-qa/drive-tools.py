#!/usr/bin/env python3
"""Calls the simulator tools through the QA bundle's yardlet-mcp, as a harness would, from the launch the panel
fixture wrote (SimulatorPanelQA): the list, a tool before any attach, the attach (which waits on the person's card,
which the fixture allows), screenshots the screen's size, the platform's buttons, taps and swipes, a paste in Korean
and keys into a search field, and arguments out of bounds. On iOS the search is the home screen's, on Android the
Settings app's, which the script opens with adb as an agent's own tools would. Writes every reply to tools.json and
each screenshot to tool-<n>.<format> in the output folder, and prints one line for each check. Exits 1 when a check
failed.

usage: drive-tools.py LAUNCH_JSON DEVICE_ID OUTPUT_FOLDER [ios | android ADB]
"""
import base64
import json
import os
import re
import struct
import subprocess
import sys
import time


def main():
    launch_path, device, output = sys.argv[1:4]
    platform = sys.argv[4] if len(sys.argv) > 4 else "ios"
    adb = sys.argv[5] if platform == "android" else None
    units = "dp" if platform == "android" else "points"
    launch = json.load(open(launch_path))
    environment = dict(os.environ)
    environment.update(launch["env"])
    process = subprocess.Popen([launch["command"]], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               env=environment, text=True)
    next_id = 0
    replies = []
    checks = []
    shots = 0

    def request(method, params=None):
        nonlocal next_id
        next_id += 1
        message = {"jsonrpc": "2.0", "id": next_id, "method": method}
        if params is not None:
            message["params"] = params
        process.stdin.write(json.dumps(message) + "\n")
        process.stdin.flush()
        while True:
            line = process.stdout.readline()
            if not line:
                raise SystemExit("yardlet-mcp closed its output")
            reply = json.loads(line)
            if reply.get("id") == next_id:
                return reply

    def call(tool, arguments=None, wait=0.0):
        nonlocal shots
        reply = request("tools/call", {"name": tool, "arguments": arguments or {}})
        result = reply.get("result", {})
        texts = [item.get("text", "") for item in result.get("content", []) if item.get("type") == "text"]
        sizes = []
        for item in result.get("content", []):
            if item.get("type") == "image":
                shots += 1
                data = base64.b64decode(item["data"])
                extension = item["mimeType"].split("/")[-1]
                with open(os.path.join(output, f"tool-{shots}.{extension}"), "wb") as image:
                    image.write(data)
                if data[:8] == b"\x89PNG\r\n\x1a\n":
                    sizes.append(struct.unpack(">II", data[16:24]))
        error = (result.get("structuredContent") or {}).get("error") or {}
        replies.append({"tool": tool, "arguments": arguments or {}, "isError": result.get("isError", False),
                        "kind": error.get("kind"), "text": "\n".join(texts),
                        "images": sum(1 for item in result.get("content", []) if item.get("type") == "image"),
                        "sizes": sizes})
        time.sleep(wait)
        return replies[-1]

    def check(name, ok, detail=""):
        checks.append((name, ok, detail))

    def steps(sequence):
        for tool, arguments, wait in sequence:
            reply = call(tool, arguments, wait)
            check(f"{tool} {json.dumps(arguments, ensure_ascii=False)}", not reply["isError"], reply["text"])

    request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                           "clientInfo": {"name": "simulator-qa", "version": "1"}})
    process.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
    listed = [tool["name"] for tool in request("tools/list")["result"]["tools"]]
    expected = ["simulator_list", "simulator_attach", "simulator_detach", "simulator_screenshot", "simulator_tap",
                "simulator_swipe", "simulator_type", "simulator_press"]
    check("list: the task has the eight simulator tools", all(name in listed for name in expected),
          ", ".join(name for name in listed if name.startswith("simulator_")))

    devices = call("simulator_list")
    check("simulator_list: the throwaway device is listed", device in devices["text"], devices["text"][:300])
    early = call("simulator_tap", {"x": 10, "y": 10})
    check("before attaching: a tool says to attach first", early["isError"] and early["kind"] == "not_found"
          and "simulator_attach" in early["text"], early["text"][:300])

    attached = call("simulator_attach", {"device": device}, wait=1)
    size = re.search(r"(\d+)×(\d+) " + units, attached["text"])
    check(f"simulator_attach: attached, with the id and the screen's size in {units}", not attached["isError"]
          and device in attached["text"] and size is not None, attached["text"])
    check("simulator_attach: beside the person's tab", "beside" in attached["text"], attached["text"])
    if platform == "android":
        check("simulator_attach: names the adb install line", f"adb -s {device} install" in attached["text"],
              attached["text"])
    if size is None:
        return finish(process, output, replies, checks)
    width, height = int(size.group(1)), int(size.group(2))

    first = call("simulator_screenshot")
    check("simulator_screenshot: an image the screen's size", first["images"] == 1
          and f"{width}×{height} {units}" in first["text"] and first["sizes"] == [(width, height)],
          f"{first['text']} {first['sizes']}")

    if platform == "android":
        drive_android(call, check, steps, adb, device, width, height)
    else:
        drive_ios(call, check, steps, width, height)

    detached = call("simulator_detach")
    check("simulator_detach", not detached["isError"] and "Let go of" in detached["text"], detached["text"])
    finish(process, output, replies, checks)


def drive_ios(call, check, steps, width, height):
    # The Settings icon on an iPhone's first home screen page.
    settings = (round(0.843 * width), round(0.492 * height))
    middle = round(width / 2)
    steps([
        ("simulator_press", {"button": "home"}, 2),
        ("simulator_tap", {"x": settings[0], "y": settings[1]}, 4),
        ("simulator_swipe", {"x": middle, "y": round(0.74 * height), "x2": middle, "y2": round(0.34 * height)}, 2),
    ])
    scrolled = call("simulator_screenshot", {"format": "jpeg"})
    check("simulator_screenshot: jpeg", scrolled["images"] == 1, scrolled["text"])

    # Search on the home screen, a swipe down from its middle.
    steps([
        ("simulator_press", {"button": "home"}, 2),
        ("simulator_swipe", {"x": middle, "y": round(0.3 * height), "x2": middle, "y2": round(0.6 * height)}, 2),
        ("simulator_type", {"text": "안녕하세요 Yardlet"}, 1),
    ])
    call("simulator_screenshot")
    steps([
        ("simulator_press", {"key": "select_all"}, 0.5),
        ("simulator_type", {"text": "yardlet", "method": "keys"}, 1),
    ])
    call("simulator_screenshot")
    refusals(call, check, width, other_button="back")
    call("simulator_press", {"key": "escape"}, 0.5)
    call("simulator_press", {"button": "home"}, 1)


def drive_android(call, check, steps, adb, serial, width, height):
    middle = round(width / 2)
    # Home, a swipe up into the app drawer, Back out of it, Recents, Home, and the volume keys.
    steps([
        ("simulator_press", {"button": "home"}, 2),
        ("simulator_swipe", {"x": middle, "y": round(0.85 * height), "x2": middle, "y2": round(0.3 * height)}, 2),
    ])
    drawer = call("simulator_screenshot", {"format": "jpeg"})
    check("simulator_screenshot: jpeg", drawer["images"] == 1, drawer["text"])
    steps([
        ("simulator_press", {"button": "back"}, 1),
        ("simulator_press", {"button": "recents"}, 2),
        ("simulator_press", {"button": "home"}, 1),
        ("simulator_press", {"button": "volume_up"}, 1),
        ("simulator_press", {"button": "volume_down"}, 1),
    ])

    # The agent's own tools open Settings' search, whose field takes the keyboard's focus.
    opened = subprocess.run([adb, "-s", serial, "shell", "am start -W -a android.settings.APP_SEARCH_SETTINGS"],
                            capture_output=True, text=True, timeout=30)
    check("adb: Settings' search opens", opened.returncode == 0 and "Complete" in opened.stdout, opened.stderr[:300])
    time.sleep(2)
    steps([
        ("simulator_tap", {"x": round(0.45 * width), "y": round(0.088 * height)}, 1),
        ("simulator_type", {"text": "안녕하세요 Yardlet"}, 2),
    ])
    call("simulator_screenshot")
    steps([
        ("simulator_press", {"key": "select_all"}, 0.5),
        ("simulator_press", {"key": "delete"}, 0.5),
        ("simulator_type", {"text": "yardlet", "method": "keys"}, 2),
    ])
    call("simulator_screenshot")
    refusals(call, check, width, other_button="lock")

    # Power turns the screen off and on; a swipe up passes the lock screen, which has no code.
    steps([
        ("simulator_press", {"button": "back"}, 1),
        ("simulator_press", {"button": "home"}, 1),
        ("simulator_press", {"button": "power"}, 2),
        ("simulator_press", {"button": "power"}, 2),
        ("simulator_swipe", {"x": middle, "y": round(0.8 * height), "x2": middle, "y2": round(0.3 * height)}, 2),
    ])
    call("simulator_screenshot")


def refusals(call, check, width, other_button):
    for arguments, kind in [
        (("simulator_tap", {"x": width + 1, "y": 10}), "invalid_arguments"),
        (("simulator_press", {"button": other_button}), "invalid_arguments"),
        (("simulator_type", {"text": "안녕", "method": "keys"}), "invalid_arguments"),
        (("simulator_press", {"button": "home", "count": 51}), "invalid_arguments"),
    ]:
        reply = call(*arguments)
        check(f"refused: {arguments[0]} {json.dumps(arguments[1], ensure_ascii=False)}",
              reply["isError"] and reply["kind"] == kind, reply["text"][:300])


def finish(process, output, replies, checks):
    process.stdin.close()
    process.wait(timeout=10)
    with open(os.path.join(output, "tools.json"), "w") as file:
        json.dump(replies, file, ensure_ascii=False, indent=2)
    for name, ok, detail in checks:
        print(("ok    " if ok else "FAIL  ") + "simulator-tools: " + name + ("" if ok else "  " + detail))
    sys.exit(0 if checks and all(ok for _, ok, _ in checks) else 1)


if __name__ == "__main__":
    main()
