#!/bin/zsh
set -euo pipefail
export EDITOR=vim VISUAL=vim GIT_EDITOR=vim
cd "${0:A:h:h}"
swift_path=$(xcrun --find swiftc)
plugin_path="${swift_path:h:h}/lib/swift/host/plugins/testing/libTestingMacros.dylib"
flags=(--disable-xctest)
if [[ -f "$plugin_path" ]]; then
  flags+=(-Xswiftc -load-plugin-library -Xswiftc "$plugin_path")
fi
swift test "${flags[@]}" "$@"
# End to end: real key handling, list, history and clipboard writes — headless, on a private clipboard.
swift build >/dev/null
"$(swift build --show-bin-path)/SuperCopy" --self-test
