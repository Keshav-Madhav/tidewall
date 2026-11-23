#!/bin/bash
# windows/pack.sh [version] [win-arm64|win-x64 …]: Tidewall's Windows installers (Setup.exe) and update packages,
# built on this Mac with Velopack (vpk cross-packs for Windows), into windows/Releases/<rid>.
set -euo pipefail
cd "$(dirname "$0")/.."
export DOTNET_ROOT=${DOTNET_ROOT:-$HOME/.dotnet} PATH=$HOME/.dotnet:$HOME/.dotnet/tools:$PATH DOTNET_CLI_TELEMETRY_OPTOUT=1
version=${1:-$(cat VERSION)}; shift || true
rids=${@:-win-x64 win-arm64}
# this version's section of CHANGELOG.md travels in the update package: an installed copy shows it in What's New while
# the update waits (as the Mac does)
notes=$(mktemp); awk -v v="$version" '$0 ~ "^## \\[?"v {f=1; next} /^## / {f=0} f' CHANGELOG.md > "$notes"
for rid in $rids; do
  dir=windows/bin/pack/$rid
  dotnet publish windows/Tidewall.csproj -c Release -r $rid --self-contained -p:PublishSingleFile=true -p:TidewallVersion=$version -o $dir | grep -E " error |Tidewall ->" || true
  cp windows/Tidewall.ico CHANGELOG.md $dir/; rsync -a --delete themes/ $dir/themes/
  vpk "[win]" pack --packId Tidewall --packVersion $version --packDir $dir --mainExe Tidewall.exe --packTitle Tidewall \
    --packAuthors "Keshav Madhav" --icon windows/Tidewall.ico --runtime $rid --channel $rid --outputDir windows/Releases/$rid \
    --framework webview2 --releaseNotes "$notes" --yes                                          # (the installer adds WebView2 where it's missing)
done
ls -la windows/Releases/*/
