cask "notelume" do
  version "1.0.0"
  sha256 "REPLACE_WITH_DMG_SHA256"

  url "https://github.com/cybasoft/notelume/releases/download/v#{version}/NoteLume-#{version}.dmg"
  name "NoteLume"
  desc "Markdown notes for your Mac with MenuBar integration"
  homepage "https://github.com/cybasoft/notelume"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sonoma

  app "NoteLume.app"

  zap trash: [
    "~/Library/Containers/com.cybasoft.notelume",
    "~/Library/Preferences/com.cybasoft.notelume.plist",
  ]
end
