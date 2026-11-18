#!/usr/bin/env python3
"""Calls the simulator tools through the QA bundle's yardlet-mcp, as a harness would, from the launch the panel
fixture wrote (SimulatorPanelQA): the list, a tool before any attach, the attach (which waits on the person's card,
which the fixture allows), screenshots, Home, a tap on Settings, swipes, a paste and keys into Search, and arguments
out of bounds. Writes every reply to tools.json and each screenshot to tool-<n>.<format> in the output folder, and
prints one line for each check. Exits 1 when a check failed.

usage: drive-tools.py LAUNCH_JSON DEVICE_UDID OUTPUT_FOLDER
"""
import base64
import json
import os
import subprocess
import sys
import time

# An iPhone 17's screen in points, and its Settings icon on the first home screen page.
WIDTH, HEIGHT = 402, 874
SETTINGS = (round(0.843 * WIDTH), round(0.492 * HEIGHT))


def main():
    launch_path, udid, output = sys.argv[1:4]
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
        for item in result.get("content", []):
            if item.get("type") == "image":
                shots += 1
                extension = item["mimeType"].split("/")[-1]
                with open(os.path.join(output, f"tool-{shots}.{extension}"), "wb") as image:
                    image.write(base64.b64decode(item["data"]))
        error = (result.get("structuredContent") or {}).get("error") or {}
        replies.append({"tool": tool, "arguments": arguments or {}, "isError": result.get("isError", False),
                        "kind": error.get("kind"), "text": "\n".join(texts),
                        "images": sum(1 for item in result.get("content", []) if item.get("type") == "image")})
        time.sleep(wait)
        return replies[-1]

    def check(name, ok, detail=""):
        checks.append((name, ok, detail))

    request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                           "clientInfo": {"name": "simulator-qa", "version": "1"}})
    process.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
    listed = [tool["name"] for tool in request("tools/list")["result"]["tools"]]
    expected = ["simulator_list", "simulator_attach", "simulator_detach", "simulator_screenshot", "simulator_tap",
                "simulator_swipe", "simulator_type", "simulator_press"]
    check("list: the task has the eight simulator tools", all(name in listed for name in expected),
          ", ".join(name for name in listed if name.startswith("simulator_")))

    devices = call("simulator_list")
    check("simulator_list: the throwaway device is listed", udid in devices["text"], devices["text"][:300])
    early = call("simulator_tap", {"x": 10, "y": 10})
    check("before attaching: a tool says to attach first", early["isError"] and early["kind"] == "not_found"
          and "simulator_attach" in early["text"], early["text"][:300])

    attached = call("simulator_attach", {"device": udid}, wait=1)
    check("simulator_attach: attached, with the id and the screen's size", not attached["isError"]
          and udid in attached["text"] and f"{WIDTH}×{HEIGHT} points" in attached["text"], attached["text"])
    check("simulator_attach: beside the person's tab", "beside" in attached["text"], attached["text"])

    first = call("simulator_screenshot")
    check("simulator_screenshot: an image the screen's size", first["images"] == 1
          and f"{WIDTH}×{HEIGHT} points" in first["text"], first["text"])
    for step, arguments, wait in [
        ("simulator_press", {"button": "home"}, 2),
        ("simulator_tap", {"x": SETTINGS[0], "y": SETTINGS[1]}, 4),
        ("simulator_swipe", {"x": 201, "y": 650, "x2": 201, "y2": 300}, 2),
    ]:
        reply = call(step, arguments, wait)
        check(f"{step} {json.dumps(arguments)}", not reply["isError"], reply["text"])
    scrolled = call("simulator_screenshot", {"format": "jpeg"})
    check("simulator_screenshot: jpeg", scrolled["images"] == 1, scrolled["text"])

    for step, arguments, wait in [
        ("simulator_press", {"button": "home"}, 2),
        ("simulator_swipe", {"x": 201, "y": 260, "x2": 201, "y2": 520}, 2),
        ("simulator_type", {"text": "안녕하세요 Yardlet"}, 1),
    ]:
        reply = call(step, arguments, wait)
        check(f"{step} {json.dumps(arguments, ensure_ascii=False)}", not reply["isError"], reply["text"])
    call("simulator_screenshot")
    for step, arguments, wait in [
        ("simulator_press", {"key": "select_all"}, 0.5),
        ("simulator_type", {"text": "yardlet", "method": "keys"}, 1),
    ]:
        reply = call(step, arguments, wait)
        check(f"{step} {json.dumps(arguments)}", not reply["isError"], reply["text"])
    call("simulator_screenshot")

    for arguments, kind in [
        (("simulator_tap", {"x": WIDTH + 1, "y": 10}), "invalid_arguments"),
        (("simulator_press", {"button": "back"}), "invalid_arguments"),
        (("simulator_type", {"text": "안녕", "method": "keys"}), "invalid_arguments"),
        (("simulator_press", {"button": "home", "count": 51}), "invalid_arguments"),
    ]:
        reply = call(*arguments)
        check(f"refused: {arguments[0]} {json.dumps(arguments[1], ensure_ascii=False)}",
              reply["isError"] and reply["kind"] == kind, reply["text"][:300])

    call("simulator_press", {"key": "escape"}, 0.5)
    call("simulator_press", {"button": "home"}, 1)
    detached = call("simulator_detach")
    check("simulator_detach", not detached["isError"] and "Let go of" in detached["text"], detached["text"])

    process.stdin.close()
    process.wait(timeout=10)
    with open(os.path.join(output, "tools.json"), "w") as file:
        json.dump(replies, file, ensure_ascii=False, indent=2)
    for name, ok, detail in checks:
        print(("ok    " if ok else "FAIL  ") + "simulator-tools: " + name + ("" if ok else "  " + detail))
    sys.exit(0 if all(ok for _, ok, _ in checks) else 1)


if __name__ == "__main__":
    main()
