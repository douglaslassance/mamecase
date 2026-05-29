cask "mamecase" do
  version "{{VERSION}}"
  sha256 "{{SHA256}}"

  url "https://api.douglaslassance.me/mamecase/download/#{version}/aarch64-apple-darwin"
  name "Mamecase"
  desc "MAME front-end"
  homepage "https://github.com/douglaslassance/mamecase"

  livecheck do
    url "https://api.douglaslassance.me/mamecase"
    strategy :json do |json|
      json["latest"]
    end
  end

  depends_on macos: :sonoma

  app "Mamecase.app"

  zap trash: [
    "~/Library/Application Support/Mamecase",
    "~/Library/Caches/Mamecase",
    "~/Library/Preferences/me.douglaslassance.mamecase.plist",
  ]
end
