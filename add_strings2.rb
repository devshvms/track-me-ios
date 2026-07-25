require 'xcodeproj'

project_path = 'track-me-ios.xcodeproj'
project = Xcodeproj::Project.open(project_path)

# 1. Update knownRegions
project.root_object.known_regions = ["en", "Base", "es", "fr", "de", "hi", "ja", "zh-Hans"]

project.save
puts "Updated knownRegions."
