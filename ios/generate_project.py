from __future__ import annotations

import pathlib

ROOT = pathlib.Path(__file__).parent
PROJECT = ROOT / "AgentMonitor.xcodeproj" / "project.pbxproj"

objects: list[str] = []

def add(identifier: str, value: str) -> None:
    objects.append(f"\t\t{identifier} = {value};")

# Explicit groups keep Info.plist and signing entitlements out of Swift compilation.
add("A00000000000000000000001", "{isa = PBXBuildFile; fileRef = A00000000000000000000002 /* AgentMonitorApp.swift */; }")
add("A00000000000000000000002", "{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = AgentMonitorApp.swift; sourceTree = \"<group>\"; }")
add("A00000000000000000000020", "{isa = PBXBuildFile; fileRef = A00000000000000000000021 /* MonitorViews.swift */; }")
add("A00000000000000000000021", "{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = MonitorViews.swift; sourceTree = \"<group>\"; }")
add("A00000000000000000000022", "{isa = PBXBuildFile; fileRef = A00000000000000000000023 /* MonitorModels.swift */; }")
add("A00000000000000000000023", "{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = MonitorModels.swift; sourceTree = \"<group>\"; }")
add("A00000000000000000000003", "{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = \"<group>\"; }")
add("A00000000000000000000004", "{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = AgentMonitor.entitlements; sourceTree = \"<group>\"; }")
add("A0000000000000000000001C", "{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = AgentMonitor-Production.entitlements; sourceTree = \"<group>\"; }")
add("A00000000000000000000030", "{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = \"<group>\"; }")
add("A00000000000000000000031", "{isa = PBXBuildFile; fileRef = A00000000000000000000030 /* Assets.xcassets */; }")
add("A00000000000000000000005", "{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = AgentMonitor.app; sourceTree = BUILT_PRODUCTS_DIR; }")

# Phone-only source that talks to the watch.
add("A00000000000000000000024", "{isa = PBXBuildFile; fileRef = A00000000000000000000025 /* PhoneWatchLink.swift */; }")
add("A00000000000000000000025", "{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = PhoneWatchLink.swift; sourceTree = \"<group>\"; }")

# Shared, Foundation-only sources compiled into both apps.
add("A00000000000000000000026", "{isa = PBXBuildFile; fileRef = A00000000000000000000027 /* MonitorAPI.swift */; }")
add("A00000000000000000000027", "{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = MonitorAPI.swift; sourceTree = \"<group>\"; }")

# watchOS app sources.
add("B00000000000000000000001", "{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = AgentWatchApp.swift; sourceTree = \"<group>\"; }")
add("B00000000000000000000002", "{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = WatchStore.swift; sourceTree = \"<group>\"; }")
add("B00000000000000000000003", "{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = WatchViews.swift; sourceTree = \"<group>\"; }")
add("B00000000000000000000004", "{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = \"<group>\"; }")
add("B00000000000000000000010", "{isa = PBXBuildFile; fileRef = B00000000000000000000001 /* AgentWatchApp.swift */; }")
add("B00000000000000000000011", "{isa = PBXBuildFile; fileRef = B00000000000000000000002 /* WatchStore.swift */; }")
add("B00000000000000000000012", "{isa = PBXBuildFile; fileRef = B00000000000000000000003 /* WatchViews.swift */; }")
add("B00000000000000000000013", "{isa = PBXBuildFile; fileRef = A00000000000000000000027 /* MonitorAPI.swift */; }")
add("B00000000000000000000014", "{isa = PBXBuildFile; fileRef = A00000000000000000000023 /* MonitorModels.swift */; }")
add("B00000000000000000000080", "{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = \"<group>\"; }")
add("B00000000000000000000081", "{isa = PBXBuildFile; fileRef = B00000000000000000000080 /* Assets.xcassets */; }")
add("B00000000000000000000007", "{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = AgentMonitorWatch.app; sourceTree = BUILT_PRODUCTS_DIR; }")

add("A00000000000000000000006", "{isa = PBXGroup; children = (A00000000000000000000007, B00000000000000000000070, B00000000000000000000071, A00000000000000000000008,); sourceTree = \"<group>\"; }")
add("A00000000000000000000007", "{isa = PBXGroup; children = (A00000000000000000000002, A00000000000000000000025, A00000000000000000000021, A00000000000000000000023, A00000000000000000000003, A00000000000000000000004, A0000000000000000000001C, A00000000000000000000030,); path = AgentMonitor; sourceTree = \"<group>\"; }")
add("B00000000000000000000070", "{isa = PBXGroup; children = (A00000000000000000000027,); path = Shared; sourceTree = \"<group>\"; }")
add("B00000000000000000000071", "{isa = PBXGroup; children = (B00000000000000000000001, B00000000000000000000002, B00000000000000000000003, B00000000000000000000004, B00000000000000000000080,); path = AgentWatch; sourceTree = \"<group>\"; }")
add("A00000000000000000000008", "{isa = PBXGroup; children = (A00000000000000000000005, B00000000000000000000007,); name = Products; sourceTree = \"<group>\"; }")

add("A00000000000000000000009", "{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (A00000000000000000000001, A00000000000000000000024, A00000000000000000000026, A00000000000000000000020, A00000000000000000000022,); runOnlyForDeploymentPostprocessing = 0; }")
add("A0000000000000000000000A", "{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }")
add("A0000000000000000000000B", "{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (A00000000000000000000031,); runOnlyForDeploymentPostprocessing = 0; }")
add("B00000000000000000000060", "{isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = \"$(CONTENTS_FOLDER_PATH)/Watch\"; dstSubfolderSpec = 16; files = (B00000000000000000000015,); name = \"Embed Watch Content\"; runOnlyForDeploymentPostprocessing = 0; }")
add("B00000000000000000000015", "{isa = PBXBuildFile; fileRef = B00000000000000000000007 /* AgentMonitorWatch.app */; settings = {ATTRIBUTES = (RemoveHeadersOnCopy, ); }; }")
add("A0000000000000000000000C", "{isa = PBXNativeTarget; buildConfigurationList = A0000000000000000000001A; buildPhases = (A0000000000000000000000A, A00000000000000000000009, A0000000000000000000000B, B00000000000000000000060,); buildRules = (); dependencies = (B00000000000000000000051,); name = AgentMonitor; productName = AgentMonitor; productReference = A00000000000000000000005; productType = \"com.apple.product-type.application\"; }")

# watchOS app: a single target with WKApplication in its Info.plist, embedded in the phone app.
add("B00000000000000000000020", "{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (B00000000000000000000010, B00000000000000000000011, B00000000000000000000012, B00000000000000000000013, B00000000000000000000014,); runOnlyForDeploymentPostprocessing = 0; }")
add("B00000000000000000000021", "{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }")
add("B00000000000000000000022", "{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (B00000000000000000000081,); runOnlyForDeploymentPostprocessing = 0; }")
add("B00000000000000000000030", "{isa = PBXNativeTarget; buildConfigurationList = B00000000000000000000040; buildPhases = (B00000000000000000000021, B00000000000000000000020, B00000000000000000000022,); buildRules = (); dependencies = (); name = AgentMonitorWatch; productName = AgentMonitorWatch; productReference = B00000000000000000000007; productType = \"com.apple.product-type.application\"; }")
add("B00000000000000000000050", "{isa = PBXContainerItemProxy; containerPortal = A0000000000000000000000D; proxyType = 1; remoteGlobalIDString = B00000000000000000000030; remoteInfo = AgentMonitorWatch; }")
add("B00000000000000000000051", "{isa = PBXTargetDependency; target = B00000000000000000000030; targetProxy = B00000000000000000000050; }")

add("A0000000000000000000000D", "{isa = PBXProject; attributes = {BuildIndependentTargetsInParallel = 1; LastUpgradeCheck = 2700; TargetAttributes = {A0000000000000000000000C = {CreatedOnToolsVersion = 27.1; ProvisioningStyle = Automatic; }; B00000000000000000000030 = {CreatedOnToolsVersion = 27.1; ProvisioningStyle = Automatic; }; }; }; buildConfigurationList = A0000000000000000000001B; compatibilityVersion = \"Xcode 16.0\"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base,); mainGroup = A00000000000000000000006; productRefGroup = A00000000000000000000008; projectDirPath = \"\"; projectRoot = \"\"; targets = (A0000000000000000000000C, B00000000000000000000030,); }")
add("A0000000000000000000000E", "{isa = XCConfigurationList; buildConfigurations = (A00000000000000000000013, A00000000000000000000014,); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }")
add("A0000000000000000000000F", "{isa = XCConfigurationList; buildConfigurations = (A00000000000000000000015, A00000000000000000000016,); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }")
add("B00000000000000000000040", "{isa = XCConfigurationList; buildConfigurations = (B00000000000000000000041, B00000000000000000000042,); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }")

project_settings = "{ALWAYS_SEARCH_USER_PATHS = NO; CLANG_ENABLE_MODULES = YES; CLANG_ENABLE_OBJC_ARC = YES; IPHONEOS_DEPLOYMENT_TARGET = 17.0; SDKROOT = iphoneos; SWIFT_VERSION = 5.0;}"
target_settings = "{ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon; CODE_SIGN_ENTITLEMENTS = AgentMonitor/AgentMonitor.entitlements; CODE_SIGN_STYLE = Automatic; GENERATE_INFOPLIST_FILE = NO; INFOPLIST_FILE = AgentMonitor/Info.plist; IPHONEOS_DEPLOYMENT_TARGET = 17.0; LD_RUNPATH_SEARCH_PATHS = (\"$(inherited)\", \"@executable_path/Frameworks\"); PRODUCT_BUNDLE_IDENTIFIER = org.nousresearch.agent-monitor; PRODUCT_NAME = \"$(TARGET_NAME)\"; SUPPORTED_PLATFORMS = \"iphoneos iphonesimulator\"; SWIFT_VERSION = 5.0; TARGETED_DEVICE_FAMILY = \"1,2\";}"
release_target_settings = target_settings.replace("AgentMonitor/AgentMonitor.entitlements", "AgentMonitor/AgentMonitor-Production.entitlements")
# Without this the app's #if DEBUG blocks never compile in.
debug_target_settings = target_settings.replace("SWIFT_VERSION = 5.0;", "SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG; SWIFT_VERSION = 5.0;")
add("A00000000000000000000013", f"{{isa = XCBuildConfiguration; buildSettings = {project_settings}; name = Debug; }}")
add("A00000000000000000000014", f"{{isa = XCBuildConfiguration; buildSettings = {project_settings}; name = Release; }}")
add("A00000000000000000000015", f"{{isa = XCBuildConfiguration; buildSettings = {debug_target_settings}; name = Debug; }}")
add("A00000000000000000000016", f"{{isa = XCBuildConfiguration; buildSettings = {release_target_settings}; name = Release; }}")
add("A0000000000000000000001A", "{isa = XCConfigurationList; buildConfigurations = (A00000000000000000000015, A00000000000000000000016,); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }")
add("A0000000000000000000001B", "{isa = XCConfigurationList; buildConfigurations = (A00000000000000000000013, A00000000000000000000014,); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }")

watch_settings = "{ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon; CODE_SIGN_STYLE = Automatic; GENERATE_INFOPLIST_FILE = NO; INFOPLIST_FILE = AgentWatch/Info.plist; PRODUCT_BUNDLE_IDENTIFIER = org.nousresearch.agent-monitor.watchkitapp; PRODUCT_NAME = \"$(TARGET_NAME)\"; SDKROOT = watchos; SUPPORTED_PLATFORMS = \"watchos watchsimulator\"; SWIFT_VERSION = 5.0; TARGETED_DEVICE_FAMILY = 4; WATCHOS_DEPLOYMENT_TARGET = 10.0;}"
watch_debug_settings = watch_settings.replace("SWIFT_VERSION = 5.0;", "SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG; SWIFT_VERSION = 5.0;")
add("B00000000000000000000041", f"{{isa = XCBuildConfiguration; buildSettings = {watch_debug_settings}; name = Debug; }}")
add("B00000000000000000000042", f"{{isa = XCBuildConfiguration; buildSettings = {watch_settings}; name = Release; }}")

PROJECT.parent.mkdir(parents=True, exist_ok=True)
text = "// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 60;\n\tobjects = {\n" + "\n".join(objects) + "\n\t};\n\trootObject = A0000000000000000000000D;\n}\n"
PROJECT.write_text(text, encoding="utf-8")
print(PROJECT)