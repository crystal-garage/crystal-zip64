# Extracts an archive created by samples/million.cr.
#
# Usage:
#   crystal run samples/extract_million.cr -- [zip_path] [dest_dir]
#
# Defaults:
#   zip_path:  out.zip
#   dest_dir:  out_extracted
#
# Notes:
# - Uses Zip64::Reader (streaming) so it doesn't need to load the full central directory.
# - Applies basic path sanitization to avoid writing outside dest_dir (Zip-Slip).

require "../src/zip64"

if ARGV.includes?("-h") || ARGV.includes?("--help")
  puts "Usage: crystal run samples/extract_million.cr -- [zip_path] [dest_dir]"
  puts "Defaults: zip_path=out.zip, dest_dir=out_extracted"
  exit 0
end

zip_path = ARGV[0]? || "out.zip"
dest_dir = ARGV[1]? || "out_extracted"

unless ::File.exists?(zip_path)
  STDERR.puts "Zip file not found: #{zip_path}"
  STDERR.puts "Tip: run samples/million.cr first to generate out.zip"
  exit 1
end

Dir.mkdir_p(dest_dir)

# Returns a relative, safe path (using forward slashes in ZIP names), or nil to skip.
private def safe_relative_path(name : String) : String?
  # Reject absolute paths and Windows drive paths.
  return if name.starts_with?("/") || name.starts_with?("\\")
  return if name.size >= 2 && name[1] == ':'

  # Split on both separators to be safe.
  parts = name.split(/[\\\/]+/).reject(&.empty?)
  return if parts.any? &.==("..")

  parts.join(File::SEPARATOR)
end

extracted = 0_i64
skipped = 0_i64

Zip64::Reader.open(zip_path) do |zip|
  zip.each_entry do |entry|
    rel = safe_relative_path(entry.filename)
    unless rel
      skipped += 1
      next
    end

    out_path = ::File.join(dest_dir, rel)

    if entry.dir?
      Dir.mkdir_p(out_path)
    else
      parent = ::File.dirname(out_path)
      Dir.mkdir_p(parent) unless parent == "."

      ::File.open(out_path, "w") do |file|
        IO.copy(entry.io, file)
      end
    end

    extracted += 1
    if (extracted % 100_000) == 0
      puts "extracted #{extracted} entries..."
    end
  end
end

puts "done"
puts "extracted: #{extracted}"
puts "skipped:   #{skipped}"
puts "dest:      #{dest_dir}"
