require "../../spec_helper"

describe Compress::Zip64 do
  it "writes and reads to memory" do
    io = IO::Memory.new

    Compress::Zip64::Writer.open(io) do |zip|
      zip.add "foo.txt", &.print("contents of foo")
      zip.add "bar.txt", &.print("contents of bar")
    end

    io.rewind

    Compress::Zip64::Reader.open(io) do |zip|
      entry = zip.next_entry.not_nil!
      entry.file?.should be_true
      entry.dir?.should be_false
      entry.filename.should eq("foo.txt")
      entry.compression_method.should eq(Compress::Zip64::CompressionMethod::DEFLATED)
      entry.crc32.should eq(0)
      entry.compressed_size.should eq(0)
      entry.uncompressed_size.should eq(0)
      entry.extra.should_not be_empty # Contains the timestamp extra as well
      entry.io.gets_to_end.should eq("contents of foo")

      entry = zip.next_entry.not_nil!
      entry.filename.should eq("bar.txt")
      entry.io.gets_to_end.should eq("contents of bar")

      zip.next_entry.should be_nil
    end
  end

  it "writes entry" do
    io = IO::Memory.new

    time = Time.utc(2017, 1, 14, 2, 3, 4)
    extra = Bytes[1, 2, 3, 4]

    Compress::Zip64::Writer.open(io) do |zip|
      zip.add(Compress::Zip64::Writer::Entry.new("foo.txt", time: time, extra: extra)) do |_io|
        _io.print("contents of foo")
      end
    end

    io.rewind

    Compress::Zip64::Reader.open(io) do |zip|
      entry = zip.next_entry.not_nil!
      entry.filename.should eq("foo.txt")
      entry.time.should eq(time)
      entry.extra[9, 4].should eq(extra) # Serializer writes out the improved timestamp
      entry.io.gets_to_end.should eq("contents of foo")
    end
  end

  it "writes entry uncompressed" do
    io = IO::Memory.new

    text = "contents of foo"
    crc32 = Digest::CRC32.checksum(text)

    Compress::Zip64::Writer.open(io) do |zip|
      entry = Compress::Zip64::Writer::Entry.new("foo.txt")
      entry.compression_method = Compress::Zip64::CompressionMethod::STORED
      entry.crc32 = crc32
      entry.compressed_size = text.bytesize.to_u64
      entry.uncompressed_size = text.bytesize.to_u64
      zip.add entry, &.print(text)

      entry = Compress::Zip64::Writer::Entry.new("bar.txt")
      entry.compression_method = Compress::Zip64::CompressionMethod::STORED
      entry.crc32 = crc32
      entry.compressed_size = text.bytesize.to_u64
      entry.uncompressed_size = text.bytesize.to_u64
      zip.add entry, &.print(text)
    end

    io.rewind

    Compress::Zip64::Reader.open(io) do |zip|
      entry = zip.next_entry.not_nil!
      entry.filename.should eq("foo.txt")
      entry.compression_method.should eq(Compress::Zip64::CompressionMethod::STORED)
      entry.crc32.should eq(crc32)
      entry.compressed_size.should eq(text.bytesize)
      entry.uncompressed_size.should eq(text.bytesize)
      entry.io.gets_to_end.should eq(text)

      entry = zip.next_entry.not_nil!
      entry.filename.should eq("bar.txt")
      entry.io.gets_to_end.should eq(text)
    end
  end

  it "writes entry uncompressed and reads with Compress::Zip64::File" do
    io = IO::Memory.new

    text = "contents of foo"
    crc32 = Digest::CRC32.checksum(text)

    Compress::Zip64::Writer.open(io) do |zip|
      entry = Compress::Zip64::Writer::Entry.new("foo.txt")
      entry.compression_method = Compress::Zip64::CompressionMethod::STORED
      entry.crc32 = crc32
      entry.compressed_size = text.bytesize.to_u64
      entry.uncompressed_size = text.bytesize.to_u64
      zip.add entry, &.print(text)
    end

    io.rewind

    Compress::Zip64::File.open(io) do |zip|
      zip.entries.size.should eq(1)
      entry = zip.entries.first
      entry.filename.should eq("foo.txt")
      entry.open(&.gets_to_end).should eq(text)
    end
  end

  it "adds a directory" do
    io = IO::Memory.new

    Compress::Zip64::Writer.open(io) do |zip|
      zip.add_dir "one"
      zip.add_dir "two/"
    end

    io.rewind

    Compress::Zip64::Reader.open(io) do |zip|
      entry = zip.next_entry.not_nil!
      entry.filename.should eq("one/")
      entry.file?.should be_false
      entry.dir?.should be_true
      entry.io.gets_to_end.should eq("")

      entry = zip.next_entry.not_nil!
      entry.filename.should eq("two/")
      entry.dir?.should be_true
      entry.io.gets_to_end.should eq("")
    end
  end

  it "writes string" do
    io = IO::Memory.new

    Compress::Zip64::Writer.open(io) do |zip|
      zip.add "foo.txt", "contents of foo"
    end

    io.rewind

    Compress::Zip64::Reader.open(io) do |zip|
      entry = zip.next_entry.not_nil!
      entry.filename.should eq("foo.txt")
      entry.io.gets_to_end.should eq("contents of foo")
    end
  end

  it "writes bytes" do
    io = IO::Memory.new

    Compress::Zip64::Writer.open(io) do |zip|
      zip.add "foo.txt", "contents of foo".to_slice
    end

    io.rewind

    Compress::Zip64::Reader.open(io) do |zip|
      entry = zip.next_entry.not_nil!
      entry.filename.should eq("foo.txt")
      entry.io.gets_to_end.should eq("contents of foo")
    end
  end

  it "writes io" do
    io = IO::Memory.new
    data = IO::Memory.new("contents of foo")

    Compress::Zip64::Writer.open(io) do |zip|
      zip.add "foo.txt", data
    end

    io.rewind

    Compress::Zip64::Reader.open(io) do |zip|
      entry = zip.next_entry.not_nil!
      entry.filename.should eq("foo.txt")
      entry.io.gets_to_end.should eq("contents of foo")
    end
  end

  it "raises a DuplicateEntryFilename when trying to add the same filename twice" do
    io = IO::Memory.new
    expect_raises(Compress::Zip64::Writer::DuplicateEntryFilename) do
      Compress::Zip64::Writer.open(io) do |zip|
        zip.add "foo.txt", "The first foo"
        zip.add "foo.txt", "The second foo"
      end
    end
  end

  it "writes file" do
    io = IO::Memory.new
    filename = datapath("test_file.txt")

    Compress::Zip64::Writer.open(io) do |zip|
      file = File.open(filename)
      zip.add "foo.txt", file
      file.closed?.should be_true
    end

    io.rewind

    Compress::Zip64::Reader.open(io) do |zip|
      entry = zip.next_entry.not_nil!
      entry.filename.should eq("foo.txt")
      entry.io.gets_to_end.should eq(File.read(filename))
    end
  end

  typeof(Compress::Zip64::Reader.new("file.zip"))
  typeof(Compress::Zip64::Reader.open("file.zip") { })

  typeof(Compress::Zip64::Writer.new("file.zip"))
  typeof(Compress::Zip64::Writer.open("file.zip") { })
end
