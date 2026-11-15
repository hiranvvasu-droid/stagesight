# Render deployment

## Current deployment

- Website: **https://stagesight-web.onrender.com/**
- Source: **https://github.com/Dhairya19793/stagesight-web**, branch `main`.
- Render service: `stagesight-web`, Free Node Web Service.
- Initial successful deployment: November 14, 2026, source commit `0e36c4e`.
- Supabase Auth Site URL and redirect entry: `https://stagesight-web.onrender.com/`.
- OpenAI key: configured in Render's private environment; no secret is stored in this repository.

Verified at deployment: HTTPS homepage and sign-in UI, `/api/health` returning `200`, AI configured status, MediaPipe JS/WASM delivery, rejection of anonymous analysis requests with `401`, and private env-file URL returning `404`. Actual recording/upload/report/playback/deletion, two-account isolation, and phone tests are still pending.

## Reproduce or update

Deploy this directory as the root of a GitHub repository. Exclude .env.local and all other real secret files regardless of repository visibility; .gitignore is included. Keep the MediaPipe models and WASM in dist/vendor, because they are served locally.

Create a Render **Web Service**, not a Static Site. Select Node, Free instance, build command `npm run check`, start command `npm start`, health path `/api/health`. Set `HOST=0.0.0.0` and `OPENAI_API_KEY` in Render's private environment settings. Optional model settings are listed in .env.example. Render provides PORT. Node 22 is declared in package.json. render.yaml contains the same configuration for Blueprint deployment.

Do not copy the local Windows certificate bundle or NODE_EXTRA_CA_CERTS setting to Render. Use Render's normal TLS trust settings. Never upload .env.local into GitHub, even for a private repository.

After deployment, change Supabase Authentication's Site URL to the actual HTTPS Render origin and configure its allowed redirect URLs. Keep localhost as an allowed development redirect only if needed. Then test signup, email confirmation, sign-in, camera/mic, saving, overlays, replay, AI reports, and deletion. Verify cross-device access and isolation between two accounts.

The free service sleeps after inactivity and has an ephemeral filesystem. Videos and reports are stored in Supabase, not on Render disk. No retention or transcoding worker is deployed.
