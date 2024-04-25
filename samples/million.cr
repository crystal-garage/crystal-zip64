# https://github.com/crystal-lang/crystal/issues/14534
# No error with `Zip64`

require "../src/zip64"

dest = "out.zip"
ii = 0
begin
  File.open(dest, "w") do |zipFile|
    Zip64::Writer.open(zipFile) do |zip|
      1000000.times do |i|
        ii = i

        max = 5 * 1024
        totalBytes = Random.rand(100..max)
        zip.add "file#{i}", Random.new.random_bytes(totalBytes)
      end
    end
  end
rescue e
  puts "## Failed adding file to zip on loop #{ii}: #{e.message}"
  puts e.inspect_with_backtrace
end
puts "done"
