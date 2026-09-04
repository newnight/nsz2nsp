#!/bin/bash
# Install a Finder Quick Action (右键 → 快速操作 → 解压 NSZ).
# Usage: ./install_finder_service.sh [/path/to/Nsz.app]
set -euo pipefail
cd "$(dirname "$0")"

APP_PATH="${1:-$PWD/build/Nsz.app}"
if [ ! -d "$APP_PATH" ]; then
  echo "ERROR: app not found at $APP_PATH" >&2
  exit 1
fi
APP_PATH="${APP_PATH%/}"
APP_PATH="${APP_PATH/#\~/$HOME}"

WF_DIR="$HOME/Library/Services/解压 NSZ.workflow"
mkdir -p "$WF_DIR/Contents"

python3 - "$WF_DIR" "$APP_PATH" <<'PYEOF'
import plistlib, sys, os

wf_dir, app_path = sys.argv[1], sys.argv[2]
name = "解压 NSZ"

info = {
    "CFBundleName": name,
    "CFBundleDisplayName": name,
    "CFBundleIdentifier": "com.biu.nszapp.quickaction",
    "CFBundleVersion": "1.0",
    "CFBundleInfoDictionaryVersion": "6.0",
    "NSServices": [
        {
            "NSMenuItem": {"default": name},
            "NSMessage": "runWorkflowAsService",
            "NSSendFileTypes": ["public.item"],
        }
    ],
}
with open(os.path.join(wf_dir, "Contents", "Info.plist"), "wb") as f:
    plistlib.dump(info, f)

script = 'open -a "%s" "$@"\n' % app_path

wflow = {
    "AMApplicationBuild": "528",
    "AMApplicationVersion": "2.10",
    "AMDocumentVersion": "2",
    "actions": [
        {
            "action": {
                "AMAccepts": {
                    "Container": "List",
                    "Optional": True,
                    "Types": ["com.apple.cocoa.path"],
                },
                "AMActionVersion": "2.0.3",
                "AMApplication": ["Automator"],
                "AMParameterProperties": {"COMMAND_STRING": {}, "inputMethod": {}, "shell": {}},
                "AMProvides": {
                    "Container": "List",
                    "Optional": True,
                    "Types": ["com.apple.cocoa.path"],
                },
                "ActionBundlePath": "/System/Library/Automator/Run Shell Script.action",
                "ActionName": "Run Shell Script",
                "ActionParameters": {
                    "COMMAND_STRING": script,
                    "CheckedForUser": True,
                    "inputMethod": 1,  # pass input as arguments ($@)
                    "shell": "/bin/zsh",
                },
                "BundleIdentifier": "com.apple.RunShellScript",
                "CFBundleVersion": "2.0.3",
                "CanShowSelectedItemsWhenRun": False,
                "CanShowWhenRun": True,
                "Category": [],
                "Class Name": "RunShellScriptAction",
                "InputUUID": "NSZ-INPUT-UUID",
                "Keywords": ["Shell"],
                "OutputUUID": "NSZ-OUTPUT-UUID",
                "UUID": "NSZ-ACTION-UUID",
                "UnlocalizedApplications": ["Automator"],
                "arguments": {
                    "0": {"default value": 0, "name": "inputMethod", "required": "0", "type": "0"},
                    "1": {"default value": "", "name": "COMMAND_STRING", "required": "0", "type": "0"},
                    "2": {"default value": "/bin/zsh", "name": "shell", "required": "0", "type": "0"},
                },
                "isViewVisible": 1,
                "location": "309.000000:253.000000",
                "nibPath": "/System/Library/Automator/Run Shell Script.action/Contents/Resources/Base.lproj/main.nib",
            },
            "isViewVisible": 1,
        }
    ],
    "connectors": {},
    "workflowMetaData": {
        "applicationBundleIDsByPath": {},
        "applicationPaths": {},
        "inputTypeIdentifier": "com.apple.Automator.fileSystemObject",
        "outputTypeIdentifier": "com.apple.Automator.nothing",
        "presentationMode": 11,
        "processesInput": 0,
        "serviceApplicationBundleID": "com.apple.finder",
        "serviceApplicationPath": "/System/Library/CoreServices/Finder.app",
        "serviceInputTypeIdentifier": "com.apple.Automator.fileSystemObject",
        "serviceOutputTypeIdentifier": "com.apple.Automator.nothing",
        "serviceProcessesInput": 0,
        "systemImageName": "NSActionTemplate",
        "useAutomaticInputType": 1,
        "workflowTypeIdentifier": "com.apple.Automator.servicesMenu",
    },
}
with open(os.path.join(wf_dir, "Contents", "document.wflow"), "wb") as f:
    plistlib.dump(wflow, f)
print("workflow files written")
PYEOF

plutil -lint "$WF_DIR/Contents/Info.plist" "$WF_DIR/Contents/document.wflow"

# refresh the services cache so the menu shows up immediately
/System/Library/CoreServices/pbs -flush 2>/dev/null || true

echo "==> Installed: $WF_DIR"
echo "    App: $APP_PATH"
echo "    If it does not appear right away:"
echo "    系统设置 → 通用 → 登录项与扩展 → 快速操作 → 勾选「解压 NSZ」"
