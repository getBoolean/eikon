# Stage 1: Device shell

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An installable Dopamine package that opens, names the stack, and does not claim a guest can run.

**Architecture:** A Theos rootless UIKit application. Host tests check the copy and the package metadata on any machine. The package itself is built on macOS or Linux, where Theos is supported.

**Tech Stack:** Theos, UIKit, Objective-C, Python 3 for the host checks.

## Global Constraints

- Said “AY-kon.” Package id `com.getboolean.eikon`. Display name `Eikon`.
- Architecture `iphoneos-arm64`. Install root `/var/jb`. `Depends: firmware (>= 15.0)`.
- Version of this shell is `0.1.0`. Do not reuse the handoff's `1.0.0` hashes. That deb is not in this checkout.
- No JIT bypass and no exploit. This stage links neither Box64, Wine, nor FEX.
- Copy states that the app is not a working emulator and not a jailbreak tool.
- Do not put Theos sources, the IPA, or `.theos` on `eikon-source`.
- Do not name guest programs. Engine words allowed on the screen are Kirikiri, BGI, Ren'Py, GameMaker, and Unity, as later targets.

---

### Task 1: Package metadata

**Files:**
- Create: `Makefile`
- Create: `control`
- Test: `tests/test_shell_package.py`

**Interfaces:**
- Consumes: nothing
- Produces: package id `com.getboolean.eikon`, version `0.1.0`, architecture `iphoneos-arm64`

- [ ] **Step 1: Write the failing test**

```python
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def control_fields():
    fields = {}
    for line in (ROOT / "control").read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        key, value = line.split(":", 1)
        fields[key.strip()] = value.strip()
    return fields

def test_control_identity():
    fields = control_fields()
    assert fields["Package"] == "com.getboolean.eikon"
    assert fields["Name"] == "Eikon"
    assert fields["Version"] == "0.1.0"
    assert fields["Architecture"] == "iphoneos-arm64"
    assert fields["Depends"] == "firmware (>= 15.0)"
    assert "not a working emulator" in fields["Description"].lower()

def test_makefile_is_rootless_application():
    text = (ROOT / "Makefile").read_text(encoding="utf-8")
    assert "THEOS_PACKAGE_SCHEME = rootless" in text
    assert "APPLICATION_NAME = Eikon" in text
    assert "Eikon_INSTALL_PATH = /Applications" in text
    assert "arm64" in text
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `python -m pytest tests/test_shell_package.py -v`

Expected: FAIL because `control` and `Makefile` do not exist.

- [ ] **Step 3: Write the package files**

`control`:

```
Package: com.getboolean.eikon
Name: Eikon
Version: 0.1.0
Architecture: iphoneos-arm64
Depends: firmware (>= 15.0)
Section: Games
Author: getBoolean
Maintainer: getBoolean <https://github.com/getBoolean>
Description: Eikon. Experimental prototype. Not a working emulator.
```

`Makefile`:

```make
ARCHS = arm64
TARGET := iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = Eikon

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = Eikon

Eikon_FILES = src/main.m src/AppDelegate.m src/RootViewController.m
Eikon_FRAMEWORKS = UIKit Foundation
Eikon_CFLAGS = -fobjc-arc
Eikon_INSTALL_PATH = /Applications

include $(THEOS_MAKE_PATH)/application.mk
```

- [ ] **Step 4: Run the test and confirm it passes**

Run: `python -m pytest tests/test_shell_package.py -v`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Makefile control tests/test_shell_package.py
git commit -m "Add the rootless package identity for the Eikon shell."
```

### Task 2: The screen

**Files:**
- Create: `src/main.m`
- Create: `src/AppDelegate.h`
- Create: `src/AppDelegate.m`
- Create: `src/RootViewController.h`
- Create: `src/RootViewController.m`
- Create: `Resources/Info.plist`
- Test: `tests/test_shell_copy.py`

**Interfaces:**
- Consumes: Task 1's application target
- Produces: a root view controller whose visible strings are exactly the paragraphs below

- [ ] **Step 1: Write the failing test**

```python
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = "\n".join(
    p.read_text(encoding="utf-8")
    for p in (ROOT / "src").glob("*.m")
)

def test_screen_states_the_limits():
    assert "Not a working emulator" in SOURCE
    assert "Not a jailbreak tool" in SOURCE
    assert "FEX-Emu" in SOURCE
    assert "Wine" in SOURCE
    assert "Box64" in SOURCE

def test_screen_names_engines_without_titles():
    for engine in ("Kirikiri", "BGI", "Ren'Py", "GameMaker", "Unity"):
        assert engine in SOURCE
    assert "G:\\" not in SOURCE
    assert ".xp3" not in SOURCE
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `python -m pytest tests/test_shell_copy.py -v`

Expected: FAIL because `src` does not exist.

- [ ] **Step 3: Write the app**

`src/main.m`:

```objc
#import <UIKit/UIKit.h>
#import "AppDelegate.h"

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
```

`src/AppDelegate.h`:

```objc
#import <UIKit/UIKit.h>

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end
```

`src/AppDelegate.m`:

```objc
#import "AppDelegate.h"
#import "RootViewController.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[RootViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}

@end
```

`src/RootViewController.h`:

```objc
#import <UIKit/UIKit.h>

@interface RootViewController : UIViewController
@end
```

`src/RootViewController.m`:

```objc
#import "RootViewController.h"

@implementation RootViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.07 green:0.08 blue:0.06 alpha:1];

    UILabel *title = [[UILabel alloc] init];
    title.text = @"Eikon";
    title.textColor = [UIColor colorWithRed:0.78 green:0.96 blue:0.29 alpha:1];
    title.font = [UIFont systemFontOfSize:34 weight:UIFontWeightSemibold];

    UILabel *body = [[UILabel alloc] init];
    body.numberOfLines = 0;
    body.textColor = [UIColor colorWithWhite:0.95 alpha:1];
    body.font = [UIFont systemFontOfSize:17];
    body.text =
        @"Not a working emulator.\n"
        @"Not a jailbreak tool.\n\n"
        @"Linux guests stay on FEX-Emu. Windows guests are Wine built for this CPU, with Box64 translating only the guest.\n\n"
        @"Later targets, in order: Kirikiri and BGI, then Ren'Py and GameMaker, then Unity.";

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[title, body]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 16;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.view.layoutMarginsGuide.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.layoutMarginsGuide.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:24],
    ]];
}

@end
```

`Resources/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Eikon</string>
    <key>CFBundleIdentifier</key>
    <string>com.getboolean.eikon</string>
    <key>CFBundleName</key>
    <string>Eikon</string>
    <key>CFBundleDisplayName</key>
    <string>Eikon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>MinimumOSVersion</key>
    <string>15.0</string>
    <key>UIDeviceFamily</key>
    <array>
        <integer>1</integer>
        <integer>2</integer>
    </array>
    <key>UILaunchStoryboardName</key>
    <string></string>
    <key>UISupportedInterfaceOrientations</key>
    <array>
        <string>UIInterfaceOrientationPortrait</string>
        <string>UIInterfaceOrientationLandscapeLeft</string>
        <string>UIInterfaceOrientationLandscapeRight</string>
    </array>
</dict>
</plist>
```

Add `Eikon_RESOURCE_FILES = Resources/Info.plist` is wrong for Theos; Theos reads `Resources/Info.plist` for an application target automatically. Do not add a second plist.

- [ ] **Step 4: Run the test and confirm it passes**

Run: `python -m pytest tests/test_shell_copy.py tests/test_shell_package.py -v`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src Resources tests/test_shell_copy.py
git commit -m "Show the shell status and the later engine targets."
```

### Task 3: Build the deb on a Theos host

**Files:**
- Modify: none
- Test: the deb's control record

**Interfaces:**
- Consumes: Tasks 1 and 2
- Produces: `packages/com.getboolean.eikon_0.1.0_iphoneos-arm64.deb` (Theos names the output; the architecture suffix must be `iphoneos-arm64`)

- [ ] **Step 1: Build**

On macOS or Linux, with Theos installed and `THEOS` set:

```bash
make clean package FINALPACKAGE=1
```

Expected: a file matching `packages/*_iphoneos-arm64.deb`.

- [ ] **Step 2: Check the installed layout**

```bash
dpkg-deb -I packages/*_iphoneos-arm64.deb
dpkg-deb -c packages/*_iphoneos-arm64.deb
```

Expected: `Package: com.getboolean.eikon` and a path under `var/jb/Applications/Eikon.app/Eikon`.

- [ ] **Step 3: Install on a device already running Dopamine 2 and open it**

```bash
scp packages/*_iphoneos-arm64.deb mobile@<device>:/tmp/eikon.deb
ssh mobile@<device> 'sudo dpkg -i /tmp/eikon.deb && uiopen com.getboolean.eikon'
```

Expected: the screen shows “Not a working emulator.” and “Not a jailbreak tool.” The app does not spawn another process.

- [ ] **Step 4: Commit**

No source commit if the deb was the only new artifact. Do not commit `packages/` or `.theos/`. Add both to `.gitignore` if the build created them and they show up in `git status`.
