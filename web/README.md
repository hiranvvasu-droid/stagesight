# StageSight

**Practice your talk. See your delivery. Make the next rehearsal count.**

### [Open StageSight live →](https://stagesight-web.onrender.com/)

Deployed to Render over HTTPS on **November 14, 2026**, from this repository's `main` branch. Sign in or create an account to start practicing. The free instance may take time to wake after inactivity.

StageSight is a presentation-practice web app built for an OpenAI-sponsored hackathon. Record a rehearsal with your laptop or phone camera, save it to your private account, and return to the recording with a transcript, content coaching, and optional visual overlays.

This repository contains the rebuilt website. It is separate from the earlier `stagesight-coach` prototype. This is a working development build, not a fully validated production release; see [Verification and remaining work](#verification-and-remaining-work).

## The experience

- **Animated overview:** a full-width green sculpture, large typography, moving text band and stacked practice sections. Motion respects reduced-motion settings, with an explicit play/pause control.
- **Overview:** your session library and practice totals, with a clear empty state before your first recording. Illustrative reports are tucked into a separate examples section.
- **Practice studio:** explicit camera/microphone access, recording consent, camera preview, start/stop controls, and elapsed time.
- **Transcription:** optional browser speech recognition during rehearsal; OpenAI transcription after saving, with separate consent.
- **Visual tools:** optional MediaPipe face landmarks and common-object boxes processed on your device.
- **Private recordings:** Supabase accounts, private video storage, owner-scoped metadata, short-lived playback links, downloads, and deletion.
- **Manage sessions:** delete a recording directly from My sessions after confirmation, including its saved AI report, visual data, and metadata. Interrupted deletion can be retried.
- **Coaching:** an OpenAI-generated summary, content/structure strengths, specific improvements, and a next-practice exercise. Reports explain the limits of the available evidence.
- **Replay:** code for synchronized saved detection overlays, seeking, and timestamped framing-review moments drawn from collected samples.

## Technology

| Layer | Implementation |
| --- | --- |
| Frontend | HTML, CSS, vanilla JavaScript |
| Server | Node.js 22, built-in HTTP server and Fetch API |
| Recording | Browser `getUserMedia` and `MediaRecorder` |
| Authentication | Supabase email/password accounts |
| Metadata | Supabase PostgreSQL with row-level security |
| Files | Private Supabase Storage bucket |
| Visual inference | Locally served MediaPipe Tasks Vision **0.10.21** |
| Models | Face Landmarker and EfficientDet Lite0, model revision 1 |
| AI | OpenAI transcription and Responses APIs |
| Deployment target | Render Web Service over HTTPS |

The server has no third-party Node dependencies. MediaPipe runtime and model assets are included in `dist/vendor/mediapipe/`; their origins, sizes, and SHA-256 hashes are recorded in `assets.json`.

## Run locally

Requirements: Node.js 22, a configured Supabase project, and a browser with supported camera/recording APIs.

```sh
cp .env.example .env.local
npm run check
npm test
npm start
```

On Windows, copy `.env.example` to `.env.local` using your editor or File Explorer. Add your OpenAI key privately to `.env.local`, or set it in the server environment. Open **http://127.0.0.1:4173/**. The server reads `.env.local` without logging its values; environment settings take precedence.

Only `dist/` is served. Never point a static file server at the repository root or expose `.env.local`.

### Environment settings

| Name | Purpose | Default |
| --- | --- | --- |
| `OPENAI_API_KEY` | Private server credential for AI processing | Required for AI only |
| `OPENAI_TRANSCRIBE_MODEL` | File transcription model | `gpt-transcribe` |
| `OPENAI_REPORT_MODEL` | Structured content-coaching model | `gpt-5.6-terra` |
| `HOST` | Listening interface | `127.0.0.1` |
| `PORT` | HTTP port | `4173` |

Recording and Supabase storage do not require an OpenAI key. Without one, the AI interface reports that configuration is pending. Model availability and billing depend on the API project.

### Supabase setup

The app is currently configured for the StageSight Supabase project. To use your own project:

1. Replace the public project URL and publishable key in `dist/cloud.js` and `ai.cjs`. These public values are intended for client access; never substitute a service-role or secret key.
2. Run `supabase-schema.sql` once against a fresh project. It creates the session table, owner policies, and private `recordings` bucket. Review before applying to an existing database; it is not an idempotent migration runner.
3. Enable email/password authentication and configure email confirmation and delivery.
4. Set the Auth Site URL and allowed redirects to your local or deployed origin.
5. Test two separate accounts to confirm that neither can access the other's metadata, files, or reports.

The schema uses the account's `auth.uid()` for ownership. A recording's path is `<user-id>/<session-id>/recording`; optional `visuals.json` and `report.json` live beside it. Video bytes live in object storage, not in PostgreSQL rows.

## Privacy and evidence

- Camera and microphone access are explicit. Everyone visible or audible should know they are being recorded and agree.
- Supabase row-level security restricts session metadata and storage operations to the signed-in owner. The AI endpoint verifies the user's token and session ownership before retrieving a recording.
- Playback uses signed URLs that expire after five minutes. Reopen a session to renew its link. Anyone holding an unexpired signed URL can use it, so do not share it unintentionally.
- MediaPipe runs on device. Saved detections contain boxes and a small set of face landmark points; raw blendshape coefficients are not saved.
- No person identification or inference of emotions, personality, genuine interest, or attention is performed.
- Browser speech recognition may send audio to the browser provider. It is optional and browser dependent.
- Post-recording OpenAI processing requires separate consent. The saved recording is sent for transcription, then its transcript is used for content coaching. The report-generation request uses `store: false`; this does not override provider data-retention policies.
- AI content coaching does not claim to have assessed vocal delivery or video. It does not invent delivery scores or precise review timestamps.
- Cloud deletion removes the video, saved visual data, saved AI report, and session metadata. Downloaded copies remain on the device. Interrupted deletion may need retry/reconciliation.
- Recordings remain until explicitly deleted. **No scheduled retention cleanup or transcoding worker is active.**

## Limits and reliability

- Cloud recording limit: **50 MB per file**, configured for this bucket.
- AI processing limit: **24 MB per recording**, below the transcription endpoint's upload limit.
- Failed uploads keep the recording in the current tab for retry or download. Keep that tab open. Retries reuse the same session ID.
- Visual inference is throttled to approximately five samples per second on the main thread. It can miss faces/objects and affect performance on slower devices.
- Replay hides stale boxes rather than carrying a detection across a gap. Framing statistics describe captured samples, not audience attention or overall delivery quality.
- Browser pace and filler counts are rough transcript-derived estimates. Speaking time, pauses, and audio-energy measurements are not implemented.
- Report generation is synchronous with timeouts, cached successful results, and an in-process cooldown/job lock. Shared queues, durable job claiming, account quotas, and restart recovery are required before scaling.
- Retrying after a partial AI failure may incur another transcription charge.
- There is no resumable video upload or automatic format conversion yet.

## Project layout

```text
dist/
  index.html, style.css       Workspace interface
  app.js                     Browser recording and base UI
  cloud.js                   Supabase accounts and private session storage
  ai-client.js               Consent and coaching interface
  vision.js                  Live detections and saved replay overlays
  vendor/mediapipe/           Pinned runtime, WASM, models, provenance, license
server.cjs                   Static frontend and server API routing
ai.cjs                       Authenticated transcription/report processing
env.cjs                      Private local environment loading
ai.test.cjs                  Mocked backend behavior/security tests
supabase-schema.sql          Fresh-project database and storage policies
render.yaml                  Render Web Service configuration
.env.example                 Variable names only; no real credentials
```

## Deploy on Render

The current deployment is **https://stagesight-web.onrender.com/**. Supabase's Auth Site URL and allowed redirect entry are configured for that origin. The OpenAI key is configured privately in Render, not committed here. Instructions below describe reproducing the deployment.

Use this repository as a **Node Web Service**, not a Static Site.

1. Connect this repository to a new Render Web Service.
2. Choose Node 22 and the appropriate instance plan.
3. Build command: `npm run check`.
4. Start command: `npm start`.
5. Set `HOST=0.0.0.0`. Render supplies `PORT`.
6. Put `OPENAI_API_KEY` in Render's **private environment settings**. Never upload `.env.local` to GitHub.
7. Health-check path: `/api/health`.
8. After deployment, update Supabase's Site URL and redirect allowlist to the actual HTTPS domain, then test email confirmation and sign-in there.

`render.yaml` provides the equivalent configuration. HTTPS is needed for camera and microphone access outside localhost. Render's free service can sleep after inactivity and uses ephemeral local storage; persistent videos and reports belong in Supabase. See [DEPLOY.md](DEPLOY.md).

## Verification and remaining work

Verified during development:

- JavaScript syntax checks and local HTTP serving.
- Signup/sign-in controls and an authenticated account visible in the browser.
- Supabase private-bucket configuration and session row-level security.
- OpenAI Responses API success and transcription success using synthetic speech, without a personal recording.
- MediaPipe face/object model initialization in the browser with camera and microphone off.
- Five mocked backend tests covering anonymous access, ownership rejection, missing credentials, bounded media size, and a successful processing flow.
- Render reported a successful live deployment of commit `0e36c4e`; the deployed homepage and sign-in form were opened over HTTPS.
- Deployed health endpoint returned `200`, AI configuration reported `configured: true`, MediaPipe JS/WASM assets were served, unauthenticated analysis requests returned `401`, and the private environment-file URL returned `404`.
- Supabase's Auth Site URL and redirect entry were saved as `https://stagesight-web.onrender.com/`.

**Not yet verified end to end:** a real camera recording through cloud upload, video replay, saved visual-overlay alignment, private AI-report persistence, full deletion, mobile recording, cross-device replay, and two-account isolation. Permission-denied, device-in-use, slow-network, expired-session, and oversized-file scenarios also need hands-on testing.

Not implemented: OpenAI Realtime coaching, password recovery UI, MFA, head-direction estimates, movement-based coaching, audio-energy graphs, pause/speaking-time measurement, background transcoding, or scheduled retention cleanup. Deployment is live; those feature and end-to-end testing gaps remain.

## Development checks

```sh
npm run check
npm test
```

Tests use mocked provider responses and do not prove live account isolation or media compatibility. Keep API keys, real recordings, browser session tokens, and local trust/certificate configuration out of commits.

## Third-party assets

MediaPipe runtime/model provenance and checksums are in `dist/vendor/mediapipe/assets.json`. The upstream MediaPipe Apache 2.0 license is included in that directory. No license grant for the StageSight application itself is declared here.
