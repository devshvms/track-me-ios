require 'xcodeproj'

project_path = 'track-me-ios.xcodeproj'
project = Xcodeproj::Project.open(project_path)

# 1. Update knownRegions
project.root_object.known_regions = ["en", "Base", "es", "fr", "de", "hi", "ja", "zh-Hans"]

# 2. Add InfoPlist.xcstrings to the main group and target
target = project.targets.find { |t| t.name == 'track-me-ios' }
group = project.main_group.find_subpath(File.join('track-me-ios'), true)

# check if it already exists to be safe
file_ref = group.files.find { |f| f.path == 'InfoPlist.xcstrings' }
unless file_ref
  file_ref = group.new_file('InfoPlist.xcstrings')
  target.add_resources([file_ref])
end

project.save
puts "Added InfoPlist.xcstrings and updated knownRegions."
