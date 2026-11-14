# Presentation Coach

Fresh SwiftUI app and Node.js backend for Presentation Coach.

## Local server

From the repository root:

```sh
cd server
npm ci
npm start
```

The server loads `.env` when present. On a fresh checkout, copy `.env.example` to `.env` and enter your OpenAI API key there. Keep the key on the server. The default port is 3000. Check the server with `curl http://localhost:3000/health`.

The server currently serves a health endpoint. Realtime credentials and report generation are future steps.

## iOS app

Open `ios/PresentationCoach.xcodeproj` in Xcode and select the PresentationCoach scheme. Xcode resolves Meta Wearables Device Access Toolkit 1.0.1 via Swift Package Manager. The app target links MWDATCore and MWDATCamera. SwiftUI, AVFoundation, Vision, and Speech come from Apple's SDK.

The app starts with a placeholder screen. For a physical iPhone, select your Apple Developer team under Signing & Capabilities. Glasses pairing and capture still need implementation and device testing.
