# Signing

For a local build, run:

```sh
LUNA_ADHOC=1 LUNA_NO_NOTARIZE=1 ./make-apps.sh
```

This signs both apps ad hoc without looking for a Developer ID identity or
submitting them to Apple. The current local builds use this path. Their
signatures have been checked locally; installation on the target iMac has
not been tested.

Without `LUNA_ADHOC=1`, the script uses the first "Developer ID Application"
identity in the login keychain, with the hardened runtime enabled. If none
is available, it falls back to ad hoc signing.

# Notarization

When using a Developer ID identity, `make-apps.sh` submits both apps for
notarization if the `notarytool` keychain profile is usable and
`LUNA_NO_NOTARIZE` is unset. It staples the tickets after Apple accepts the
submissions. The default profile name is `luna`; override it with
`LUNA_NOTARY_PROFILE`.

This path needs network access and Apple Developer credentials. It was not
run during the local validation. A successful local build or signature
check does not mean the app has been notarized.

One-time setup (the password never touches the repo — `notarytool` stores
it in the login keychain):

1. <https://account.apple.com> → *Sign-In and Security* → *App-Specific
   Passwords* → generate one (name it e.g. "luna notarytool").
2. Store it:

   ```sh
   xcrun notarytool store-credentials luna \
     --apple-id YOUR_APPLE_ID_EMAIL --team-id YOUR_TEAM_ID --password xxxx-xxxx-xxxx-xxxx
   ```

   (An App Store Connect API key works too: `--key`, `--key-id`, `--issuer`.)
3. `./make-apps.sh` — look for `notarized and stapled` in the output. If a
   submission is rejected the script prints the `notarytool log` command
   that explains why.
