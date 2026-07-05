#!/bin/bash

TEAM_ID=K5U72ZNJ2W # statiksoft team ID elliot.murphy@gmail.com
xcodebuild archive -project HLSMonitor.xcodeproj -scheme HLSMonitor -configuration Release -archivePath ./build/HLSMonitor.xcarchive -destination "generic/platform=iOS" DEVELOPMENT_TEAM=$TEAM_ID -allowProvisioningUpdates
