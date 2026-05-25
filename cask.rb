cask "mamecase" do
  version "{{VERSION}}"
  sha256 "{{SHA256}}"

  url "https://github.com/douglaslassance/mamecase/releases/download/v#{version}/mamecase-#{version}-aarch64-apple-darwin.dmg"
  name "Mamecase"
  desc "MAME front-end for macOS"
  homepage "https://github.com/douglaslassance/mamecase"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "Mamecase.app"

  zap trash: [
    "~/Library/Application Support/Mamecase",
    "~/Library/Caches/me.douglaslassance.mamecase",
    "~/Library/Preferences/me.douglaslassance.mamecase.plist",
  ]
end
