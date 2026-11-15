# StageSight

StageSight helps speakers rehearse, record, and review presentations on iPhone and in the browser.

| Directory | What it contains |
| --- | --- |
| [`ios/`](ios/) | The SwiftUI app for iPhone and compatible Meta glasses. |
| [`server/`](server/) | The iOS app's Node.js backend for live coaching, transcription, and reports. |
| [`web/`](web/) | The browser app and its separate Node.js backend. See the [web README](web/README.md). |

## iOS and its backend

Open `ios/PresentationCoach.xcodeproj` and select the **PresentationCoach** scheme. Choose your Apple Developer team under **Signing & Capabilities** for device builds. To enable Google Sign-In, follow the [local Firebase setup](ios/PresentationCoach/Firebase/README.txt).

For local backend development, run `npm ci` and `npm start` in `server/`. Set `OPENAI_API_KEY` in the server environment or in a local `.env` based on `server/.env.example`. The local health endpoint is `http://localhost:3000/health`. The iOS app's deployed backend URL is set in `ios/PresentationCoach.xcconfig`.

## Web app

In `web/`, run `npm run check`, `npm test`, and `npm start`. See [web deployment instructions](web/DEPLOY.md) for environment and account setup. The web app was imported from [Dhairya19793/stagesight-web at commit 13dc1d0](https://github.com/Dhairya19793/stagesight-web/commit/13dc1d004c0c7a522a1ba46120fd3c715a6be7a0).

The two services deploy independently. If moving the web service to this repository in Render, set its **Root Directory** to `web` and preserve its existing environment variables. The iOS backend uses `server`.
