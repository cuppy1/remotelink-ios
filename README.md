# RemoteLink iOS app (home iPhone)

Lets your other devices browse and download Photos and chosen Files folders from this iPhone, after a one-time permission.

## Build (free, no Mac)
1. Push this folder to a public GitHub repo. The "Build iOS app" workflow runs on push.
2. Open the finished run under Actions and download the `RemoteLink-ipa` artifact. Unzip it to get `RemoteLink.ipa`.

## Install (Windows)
1. Install iTunes and iCloud from apple.com (not the Microsoft Store versions).
2. Install Sideloadly, plug in the iPhone, drag in `RemoteLink.ipa`, and sign in with your Apple ID.
3. On the iPhone: Settings > General > VPN & Device Management > trust your Apple ID.
4. A free Apple ID expires the app after 7 days. Re-install it with Sideloadly to renew.

## Use
1. Register "Home iPhone" in the web dashboard first.
2. Open the app, sign in, and pick "Home iPhone".
3. Switch on "Allow my other devices", tap "Allow access to Photos", and add any Files folders.
4. Keep the app open, on charge, with Auto-Lock set to Never.
