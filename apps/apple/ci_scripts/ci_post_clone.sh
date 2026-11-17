#!/bin/sh
# Xcode Cloud runs this right after cloning the repository. The Xcode
# project isn't checked in (it's generated from project.yml), so generate
# it before Xcode Cloud looks for it.
set -e
brew install xcodegen
cd "$CI_PRIMARY_REPOSITORY_PATH/apps/apple"
xcodegen generate
