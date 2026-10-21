cask "ntfs-mount" do
  version "1.0.0"
  sha256 "bb2ef00d2fd9681d3d89baa9eb2fe278b321f0593c7bf646e9985b63af84a50f"

  url "https://github.com/AJ-Gonzalez/ntfs-mount-mac/releases/download/v#{version}/NTFSMount-#{version}.zip"
  name "NTFS Mount"
  desc "Menu bar utility for read-write NTFS volumes using FUSE-T and ntfs-3g"
  homepage "https://github.com/AJ-Gonzalez/ntfs-mount-mac"

  depends_on macos: ">= :sonoma"
  depends_on arch: :arm64

  app "NTFSMount.app"

  caveats <<~EOS
    NTFS Mount needs the FUSE-T runtime, which is free for personal use:
      https://www.fuse-t.org

    On first launch, click "Install Helper" in the menu bar panel and enter
    your administrator password once.

    On macOS 26 or later, allow NTFSMount under
    System Settings > Menu Bar > Allow in the Menu Bar.

    The app is ad-hoc signed. If macOS blocks it, run:
      xattr -dr com.apple.quarantine /Applications/NTFSMount.app
  EOS
end
