# TestFlight versioning

For every new Steelbeach build uploaded to TestFlight, increment the third
component of the user-visible version (for example, 1.0.2 to 1.0.3), even for
small fixes. Update `MARKETING_VERSION` for both the app and its notification
service in `project.yml`, then regenerate the Xcode project. Use a build number
that App Store Connect accepts and keep it consistent across both targets.
