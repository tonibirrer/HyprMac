cask "hyprmac" do
  version "0.17.1"
  sha256 "5f1436c3aa4ca78a3ca1d038cf7e6ef92213f789c588a164656a2e327979f7cc"

  url "https://github.com/zacharytgray/HyprMac/releases/download/v#{version}/HyprMac-#{version}.dmg"
  name "HyprMac"
  desc "Tiling window manager for macOS inspired by Hyprland"
  homepage "https://github.com/zacharytgray/HyprMac"

  depends_on macos: :ventura

  app "HyprMac.app"

  zap trash: [
    "~/Library/Application Support/HyprMac",
  ]

  caveats <<~EOS
    HyprMac requires Accessibility permission.
    Grant it in System Settings → Privacy & Security → Accessibility.
  EOS
end
