cask "hyprmac" do
  version "0.20.0"
  sha256 "0534338d1a7d491361c5e3e7914f7c56a129ee858b1806b4c7525470bfeef626"

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
