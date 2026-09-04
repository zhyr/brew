#!/usr/bin/env ruby
# Registers DiskCleaner.swift (source) and disk_maintenance.sh (bundle resource)
# with the DynamicIsland target in DynamicIsland.xcodeproj.
#
# Idempotent: re-running is a no-op if the file references already exist.

require 'xcodeproj'

project_path = './DynamicIsland.xcodeproj'
project = Xcodeproj::Project.open(project_path)

app_target = project.targets.find { |t| t.name == 'DynamicIsland' }
raise 'App target DynamicIsland not found' unless app_target

# Find or create the managers group (where StatsManager.swift etc. live).
managers_group = project.main_group.find_subpath('DynamicIsland/managers', false) ||
                 project.main_group.find_subpath('DynamicIsland/managers', true)
raise 'DynamicIsland/managers group not found' unless managers_group

# Find or create the Resources group.
resources_group = project.main_group.find_subpath('DynamicIsland/Resources', true)

added = []

# 1) DiskCleaner.swift — source file in managers/
unless managers_group.children.any? { |c| c.respond_to?(:path) && c.path == 'DiskCleaner.swift' }
  ref = managers_group.new_reference('DiskCleaner.swift')
  app_target.add_file_references([ref])
  added << 'DiskCleaner.swift'
end

# 2) disk_maintenance.sh — bundle resource in Resources/
unless resources_group.children.any? { |c| c.respond_to?(:path) && c.path == 'disk_maintenance.sh' }
  ref = resources_group.new_reference('disk_maintenance.sh')
  ref.last_known_file_type = 'shellscript'
  # Add as a resource (not a source/compile phase) so it lands in
  # Contents/Resources/ in the built bundle.
  app_target.add_resources([ref])
  added << 'disk_maintenance.sh'
end

if added.empty?
  puts 'Nothing to add — both files are already registered.'
else
  project.save
  puts "Added to DynamicIsland target: #{added.join(', ')}"
end
