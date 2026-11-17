# Homebrew cask for the OpenHabits Mac app. Lives in the tap
# github.com/Veggies/homebrew-openhabits as Casks/openhabits.rb, so:
#   brew install --cask veggies/openhabits/openhabits
# For a new version, run tool/release_mac.sh --upload and update version
# and sha256 here and in the tap.
cask "openhabits" do
  version "0.1.1"
  sha256 "56375e3daaea48aa16945e1dce886ff649e94cd6042fb83038e1beba2bb34a94"

  url "https://github.com/Veggies/openhabits/releases/download/v#{version}/OpenHabits-#{version}-macOS.zip"
  name "OpenHabits"
  desc "Habit tracker built around small steps, synced with your own server"
  homepage "https://github.com/Veggies/openhabits"

  livecheck do
    url :url
    strategy :github_releases
  end

  depends_on macos: :tahoe

  app "OpenHabits.app"

  zap trash: "~/Library/Containers/com.ryanruddock.openhabits"
end
