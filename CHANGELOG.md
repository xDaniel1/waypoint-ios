# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Initial project scaffold: folder structure, XcodeGen `project.yml`, `.gitignore`, README, CHANGELOG, LICENSE, and gitignored `Secrets.xcconfig` / committed `Secrets.xcconfig.example` for the Google Places API key.
- Base MapKit map view centered on the user's current location, using `CLLocationUpdate.liveUpdates()` via `LocationManager` and `MapViewModel`. Shows a graceful in-app prompt with a link to Settings when location permission is denied or restricted, instead of a blank map.

## [0.1.0] - Unreleased

Initial pre-release development version. Not yet tagged.
