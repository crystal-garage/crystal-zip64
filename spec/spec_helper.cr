require "spec"
require "../src/zip64"

def datapath(*components)
  File.join("spec", "data", *components)
end
