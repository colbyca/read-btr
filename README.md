# ReadBTR

iOS reading app (SwiftUI, iOS 17+).

## Setup

Requires Xcode 16+ and Homebrew.

```
brew install xcodegen swiftlint swift-format xcbeautify fastlane
xcodegen generate
open ReadBTR.xcodeproj
```

The `.xcodeproj` is generated from `project.yml` and is not committed — re-run
`xcodegen generate` any time `project.yml` or the source file layout changes.

## Common tasks

```
xcodegen generate                          # regenerate the Xcode project
fastlane ios test                          # run unit + UI tests on the simulator
swiftlint                                  # lint
swift-format format -i -r ReadBTR ReadBTRTests ReadBTRUITests   # format
```
