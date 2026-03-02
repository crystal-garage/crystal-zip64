require "../spec_helper"

class LocalHeaderDummy
  include Zip64::FileInfo

  def initialize(io : IO)
    super(at_file_header: io)
  end
end

describe Zip64 do
  it "reads file from memory" do
    io = IO::Memory.new

    Zip64::Writer.open(io) do |zip|
      zip.add "foo.txt", "contents of foo"
      zip.add "bar.txt", "contents of bar"
    end

    io.rewind

    Zip64::File.open(io) do |zip|
      entries = zip.entries
      entries.size.should eq(2)

      foo = entries[0]
      foo.filename.should eq("foo.txt")

      bar = entries[1]
      bar.filename.should eq("bar.txt")

      zip["foo.txt"].filename.should eq("foo.txt")
      zip["bar.txt"].filename.should eq("bar.txt")
      zip["baz.txt"]?.should be_nil

      foo.open do |foo_io|
        bar.open do |bar_io|
          foo_io.gets_to_end.should eq("contents of foo")
          bar_io.gets_to_end.should eq("contents of bar")
        end
      end
    end
  end

  it "reads file from file system" do
    filename = datapath("file.zip")

    begin
      File.open(filename, "w") do |file|
        Zip64::Writer.open(file) do |zip|
          zip.add "foo.txt", "contents of foo"
          zip.add "bar.txt", "contents of bar"
        end
      end

      File.open(filename, "r") do |file|
        Zip64::File.open(file) do |zip|
          entries = zip.entries
          entries.size.should eq(2)

          foo = entries[0]
          foo.filename.should eq("foo.txt")

          bar = entries[1]
          bar.filename.should eq("bar.txt")

          zip["foo.txt"].filename.should eq("foo.txt")
          zip["bar.txt"].filename.should eq("bar.txt")
          zip["baz.txt"]?.should be_nil

          foo.open do |foo_io|
            bar.open do |bar_io|
              foo_io.gets_to_end.should eq("contents of foo")
              bar_io.gets_to_end.should eq("contents of bar")
            end
          end
        end
      end
    ensure
      File.delete(filename)
    end
  end

  it "can open entries after the original file handle is closed" do
    filename = datapath("file.zip")

    begin
      File.open(filename, "w") do |file|
        Zip64::Writer.open(file) do |zip|
          zip.add "foo.txt", "contents of foo"
        end
      end

      file = File.open(filename, "r")
      zip = Zip64::File.new(file)
      file.close

      zip["foo.txt"].open(&.gets_to_end).should eq("contents of foo")
    ensure
      zip.try &.close
      File.delete(filename)
    end
  end

  it "writes comment" do
    io = IO::Memory.new

    Zip64::Writer.open(io) do |zip|
      zip.add Zip64::Writer::Entry.new("foo.txt", comment: "some comment"),
        "contents of foo"
    end

    io.rewind

    Zip64::File.open(io) do |zip|
      zip["foo.txt"].comment.should eq("some comment")
    end
  end

  it "reads big file" do
    io = IO::Memory.new

    Zip64::Writer.open(io) do |zip|
      100.times do |i|
        zip.add "foo#{i}.txt", "some contents #{i}"
      end
    end

    io.rewind

    Zip64::File.open(io) do |zip|
      zip.entries.size.should eq(100)
    end
  end

  it "reads zip file with different extra in local file header and central directory header" do
    Zip64::File.open(datapath("test.zip")) do |zip|
      zip.entries.size.should eq(2)
      zip["one.txt"].open(&.gets_to_end).should eq("One")
      zip["two.txt"].open(&.gets_to_end).should eq("Two")
    end
  end

  it "reads zip comment" do
    io = IO::Memory.new

    Zip64::Writer.open(io) do |zip|
      zip.comment = "zip comment"
    end

    io.rewind

    Zip64::File.open(io) do |zip|
      zip.comment.should eq("zip comment")
    end
  end

  it "parses Zip64 extra sizes in local file header" do
    filename = "a.txt"
    uncompressed = 5_u64
    compressed = 5_u64
    crc32 = Digest::CRC32.checksum("Hello")

    io = IO::Memory.new
    io.write_bytes(Zip64::FileInfo::SIGNATURE.to_u32, IO::ByteFormat::LittleEndian)
    io.write_bytes(45_u16, IO::ByteFormat::LittleEndian) # version needed
    io.write_bytes(0_u16, IO::ByteFormat::LittleEndian)  # gp flags
    io.write_bytes(0_u16, IO::ByteFormat::LittleEndian)  # stored
    io.write_bytes(0_u16, IO::ByteFormat::LittleEndian)  # time
    io.write_bytes(33_u16, IO::ByteFormat::LittleEndian) # date (1980-01-01)
    io.write_bytes(crc32.to_u32, IO::ByteFormat::LittleEndian)
    io.write_bytes(UInt32::MAX, IO::ByteFormat::LittleEndian)
    io.write_bytes(UInt32::MAX, IO::ByteFormat::LittleEndian)
    io.write_bytes(filename.bytesize.to_u16, IO::ByteFormat::LittleEndian)

    # Zip64 extra: header_id(2) + data_size(2) + u_size(8) + c_size(8)
    extra = IO::Memory.new
    extra.write_bytes(0x0001_u16, IO::ByteFormat::LittleEndian)
    extra.write_bytes(16_u16, IO::ByteFormat::LittleEndian)
    extra.write_bytes(uncompressed, IO::ByteFormat::LittleEndian)
    extra.write_bytes(compressed, IO::ByteFormat::LittleEndian)
    extra_bytes = extra.to_slice

    io.write_bytes(extra_bytes.bytesize.to_u16, IO::ByteFormat::LittleEndian)
    io.write(filename.to_slice)
    io.write(extra_bytes)

    io.rewind
    io.read_bytes(UInt32, IO::ByteFormat::LittleEndian) # consume signature
    entry = LocalHeaderDummy.new(io)
    entry.uncompressed_size.should eq(uncompressed)
    entry.compressed_size.should eq(compressed)
  end

  it "reads Zip64 EOCD locator when EOCD has overflow markers" do
    serializer = Zip64::Serializer.new
    io = IO::Memory.new

    # Local file header + stored data
    data = "Hello"
    crc32 = Digest::CRC32.checksum(data)
    local_header_offset = io.pos.to_u64
    serializer.write_local_file_header(io: io,
      filename: "a.txt",
      compressed_size: data.bytesize,
      uncompressed_size: data.bytesize,
      crc32: crc32,
      gp_flags: 0,
      mtime: Time.utc,
      storage_mode: Zip64::CompressionMethod::STORED.to_i)
    io.write(data.to_slice)

    # Central directory (with Zip64 extra even though values are small)
    central_directory_at = io.pos.to_u64
    filename = "a.txt"

    io.write_bytes(Zip64::CENTRAL_DIRECTORY_HEADER_SIGNATURE.to_u32, IO::ByteFormat::LittleEndian)
    io.write(Bytes[52, 3])                               # version made by (same as serializer)
    io.write_bytes(45_u16, IO::ByteFormat::LittleEndian) # version needed (Zip64)
    io.write_bytes(0_u16, IO::ByteFormat::LittleEndian)  # gp flags
    io.write_bytes(0_u16, IO::ByteFormat::LittleEndian)  # compression method (stored)
    io.write_bytes(0_u16, IO::ByteFormat::LittleEndian)  # time
    io.write_bytes(33_u16, IO::ByteFormat::LittleEndian) # date (1980-01-01)
    io.write_bytes(crc32.to_u32, IO::ByteFormat::LittleEndian)
    io.write_bytes(UInt32::MAX, IO::ByteFormat::LittleEndian) # compressed size marker
    io.write_bytes(UInt32::MAX, IO::ByteFormat::LittleEndian) # uncompressed size marker
    io.write_bytes(filename.bytesize.to_u16, IO::ByteFormat::LittleEndian)

    zip64_extra = IO::Memory.new
    zip64_extra.write_bytes(0x0001_u16, IO::ByteFormat::LittleEndian)           # header id
    zip64_extra.write_bytes(28_u16, IO::ByteFormat::LittleEndian)               # data size
    zip64_extra.write_bytes(data.bytesize.to_u64, IO::ByteFormat::LittleEndian) # uncompressed
    zip64_extra.write_bytes(data.bytesize.to_u64, IO::ByteFormat::LittleEndian) # compressed
    zip64_extra.write_bytes(local_header_offset, IO::ByteFormat::LittleEndian)  # local header offset
    zip64_extra.write_bytes(0_u32, IO::ByteFormat::LittleEndian)                # disk start
    zip64_extra_bytes = zip64_extra.to_slice

    io.write_bytes(zip64_extra_bytes.bytesize.to_u16, IO::ByteFormat::LittleEndian) # extra length
    io.write_bytes(0_u16, IO::ByteFormat::LittleEndian)                             # comment length
    io.write_bytes(UInt16::MAX, IO::ByteFormat::LittleEndian)                       # disk number start marker
    io.write_bytes(0_u16, IO::ByteFormat::LittleEndian)                             # internal attrs
    io.write_bytes(0_u32, IO::ByteFormat::LittleEndian)                             # external attrs
    io.write_bytes(UInt32::MAX, IO::ByteFormat::LittleEndian)                       # local header offset marker
    io.write(filename.to_slice)
    io.write(zip64_extra_bytes)

    central_directory_size = (io.pos.to_u64 - central_directory_at)

    # Zip64 end of central directory record
    zip64_eocd_offset = io.pos.to_u64
    io.write_bytes(Zip64::ZIP64_END_OF_CENTRAL_DIRECTORY_SIGNATURE.to_u32, IO::ByteFormat::LittleEndian)
    io.write_bytes(44_u64, IO::ByteFormat::LittleEndian)
    io.write(Bytes[52, 3])
    io.write_bytes(45_u16, IO::ByteFormat::LittleEndian)
    io.write_bytes(0_u32, IO::ByteFormat::LittleEndian)
    io.write_bytes(0_u32, IO::ByteFormat::LittleEndian)
    io.write_bytes(1_u64, IO::ByteFormat::LittleEndian)
    io.write_bytes(1_u64, IO::ByteFormat::LittleEndian)
    io.write_bytes(central_directory_size, IO::ByteFormat::LittleEndian)
    io.write_bytes(central_directory_at, IO::ByteFormat::LittleEndian)

    # Zip64 locator
    io.write_bytes(Zip64::ZIP64_END_OF_CENTRAL_DIRECTORY_LOCATOR.to_u32, IO::ByteFormat::LittleEndian)
    io.write_bytes(0_u32, IO::ByteFormat::LittleEndian)
    io.write_bytes(zip64_eocd_offset, IO::ByteFormat::LittleEndian)
    io.write_bytes(1_u32, IO::ByteFormat::LittleEndian)

    # EOCD with overflow markers
    io.write_bytes(Zip64::END_OF_CENTRAL_DIRECTORY_HEADER_SIGNATURE.to_u32, IO::ByteFormat::LittleEndian)
    io.write_bytes(0_u16, IO::ByteFormat::LittleEndian)
    io.write_bytes(0_u16, IO::ByteFormat::LittleEndian)
    io.write_bytes(UInt16::MAX, IO::ByteFormat::LittleEndian)
    io.write_bytes(UInt16::MAX, IO::ByteFormat::LittleEndian)
    io.write_bytes(UInt32::MAX, IO::ByteFormat::LittleEndian)
    io.write_bytes(UInt32::MAX, IO::ByteFormat::LittleEndian)
    io.write_bytes(0_u16, IO::ByteFormat::LittleEndian)

    io.rewind

    Zip64::File.open(io) do |zip|
      zip.entries.size.should eq(1)
      zip["a.txt"].open(&.gets_to_end).should eq("Hello")
      zip["a.txt"].compressed_size.should eq(5)
      zip["a.txt"].uncompressed_size.should eq(5)
    end
  end

  typeof(Zip64::File.new("file.zip"))
  typeof(Zip64::File.open("file.zip") { })
end
