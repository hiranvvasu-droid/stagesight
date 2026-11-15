In Firebase project stagesight-ccf4a, add an iOS app with bundle ID com.tourey.stagesight.
Download its GoogleService-Info.plist and replace the existing file in this folder.
Do not edit the BUNDLE_ID in an old plist: the new app needs its own Firebase registration and Google OAuth client.
Set GOOGLE_REVERSED_CLIENT_ID in ios/Firebase.local.xcconfig to its REVERSED_CLIENT_ID value.
Select your friend's developer team in Xcode Signing & Capabilities before archiving.
Run on a signed iOS device and verify Google sign-in and an AI report before distributing.
The Render backend remains https://stagesight.onrender.com and already verifies tokens for stagesight-ccf4a; no Render bundle-ID change is required.
