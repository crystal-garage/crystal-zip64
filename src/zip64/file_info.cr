# Base type for file information related to zip entries.
module Zip64::FileInfo
  SIGNATURE                 = 0x04034b50
  DATA_DESCRIPTOR_SIGNATURE = 0x08074b50

  DEFLATE_END_SIGNATURE = Bytes[80, 75, 7, 8, read_only: true]

  property version : UInt16 = Zip64::VERSION
  property general_purpose_bit_flag = 0_u16
  property compression_method = CompressionMethod::DEFLATED
  property time : Time
  property crc32 = 0_u32
  property compressed_size = 0_u64
  property uncompressed_size = 0_u64
  property filename = ""
  property extra = Bytes.empty
  property comment = ""
  property offset = 0_u64

  ZIP64_EXTRA_FIELD_ID = 0x0001_u16

  # :nodoc:
  def initialize(*, at_file_header io : IO)
    @version = read(io, UInt16)
    file_name_length, extra_field_length, time = initialize_meta(io)
    @time = time
    @filename = io.read_string(file_name_length)
    if extra_field_length != 0
      @extra = Bytes.new(extra_field_length)
      io.read_fully(@extra)
    end

    apply_zip64_extra_from_local_header!
  end

  # :nodoc:
  def initialize(*, at_central_directory_header io : IO)
    read io, UInt16            # version made by
    @version = read io, UInt16 # version needed to extract
    file_name_length, extra_field_length, time = initialize_meta(io)
    @time = time
    file_comment_length = read(io, UInt16) # file comment length
    disk_number_start = read(io, UInt16)   # disk number start
    read(io, UInt16)                       # internal file attribute
    read(io, UInt32)                       # external file attribute
    offset_32 = read(io, UInt32).to_u64    # relative offset of local header
    @filename = io.read_string(file_name_length)
    if extra_field_length != 0
      @extra = Bytes.new(extra_field_length)
      io.read_fully(@extra)
    end
    if file_comment_length != 0
      @comment = io.read_string(file_comment_length)
    end

    @offset = offset_32
    apply_zip64_extra_from_central_directory!(disk_number_start, offset_32)
  end

  # :nodoc:
  def initialize_meta(io : IO)
    @general_purpose_bit_flag = read(io, UInt16)
    @compression_method = CompressionMethod.new(read(io, UInt16))
    time = read(io, UInt16)
    date = read(io, UInt16)
    time = from_dos(date, time)
    @crc32 = read(io, UInt32)
    @compressed_size = read(io, UInt32).to_u64
    @uncompressed_size = read(io, UInt32).to_u64
    file_name_length = read(io, UInt16)
    extra_field_length = read(io, UInt16)
    {file_name_length, extra_field_length, time}
  end

  private def apply_zip64_extra_from_local_header!
    # Local header: if compressed/uncompressed sizes are 0xFFFFFFFF, the Zip64 extra field
    # provides the real 64-bit values in order: uncompressed size, compressed size.
    return unless @compressed_size == UInt32::MAX.to_u64 || @uncompressed_size == UInt32::MAX.to_u64

    zip64_extra = zip64_extra_payload(@extra)
    return unless zip64_extra

    io = IO::Memory.new(zip64_extra)
    if @uncompressed_size == UInt32::MAX.to_u64
      @uncompressed_size = read(io, UInt64)
    end
    if @compressed_size == UInt32::MAX.to_u64
      @compressed_size = read(io, UInt64)
    end
  end

  private def apply_zip64_extra_from_central_directory!(disk_number_start : UInt16, offset_32 : UInt64)
    # Central directory: Zip64 extra field contains 64-bit values for any field that overflowed.
    need_uncompressed = (@uncompressed_size == UInt32::MAX.to_u64)
    need_compressed = (@compressed_size == UInt32::MAX.to_u64)
    need_offset = (offset_32 == UInt32::MAX.to_u64)
    need_disk = (disk_number_start == UInt16::MAX)
    return unless need_uncompressed || need_compressed || need_offset || need_disk

    zip64_extra = zip64_extra_payload(@extra)
    return unless zip64_extra

    io = IO::Memory.new(zip64_extra)
    if need_uncompressed
      @uncompressed_size = read(io, UInt64)
    end
    if need_compressed
      @compressed_size = read(io, UInt64)
    end
    if need_offset
      @offset = read(io, UInt64)
    end
    if need_disk
      # The Zip64 extra specifies this as a 4-byte value.
      read(io, UInt32)
    end
  end

  private def zip64_extra_payload(extra : Bytes) : Bytes?
    return if extra.empty?

    i = 0
    while i + 4 <= extra.size
      header_id = IO::Memory.new(extra[i, 2]).read_bytes(UInt16, IO::ByteFormat::LittleEndian)
      data_size = IO::Memory.new(extra[i + 2, 2]).read_bytes(UInt16, IO::ByteFormat::LittleEndian)

      payload_start = i + 4
      payload_end = payload_start + data_size
      break if payload_end > extra.size

      if header_id == ZIP64_EXTRA_FIELD_ID
        return extra[payload_start, data_size]
      end

      i = payload_end
    end

    nil
  end

  def initialize(@filename : String, @time = Time.utc, @comment = "", @extra = Bytes.empty)
  end

  # Returns `true` if this entry is a directory.
  def dir? : Bool
    filename.ends_with?('/')
  end

  # Returns `true` if this entry is a file.
  def file? : Bool
    !dir?
  end

  protected def to_io(io : IO)
    write io, SIGNATURE # 4
    write io, @version  # 2
    meta_count = meta_to_io(io)
    io << @filename
    io.write(extra)
    meta_count + 6 + @filename.bytesize + extra.size
  end

  protected def meta_to_io(io : IO)
    write io, @general_purpose_bit_flag # 2
    write io, @compression_method.value # 2
    date, time = to_dos
    write io, time                      # 2
    write io, date                      # 2
    write io, @crc32                    # 4
    write io, @compressed_size          # 4
    write io, @uncompressed_size        # 4
    write io, @filename.bytesize.to_u16 # filename length (2)
    write io, extra.size.to_u16         # extra field length (2)
    24                                  # the 24 bytes we just wrote
  end

  protected def write_data_descriptor(io : IO)
    io.write FileInfo::DEFLATE_END_SIGNATURE # 4
    write io, @crc32                         # 4
    write io, @compressed_size               # 4
    write io, @uncompressed_size             # 4
    16                                       # the 16 bytes we just wrote
  end

  protected def decompressor_for(io, is_sized = false)
    case compression_method
    when .stored?
      io = IO::Sized.new(io, compressed_size) unless is_sized
    when .deflated?
      if compressed_size == 0 && bit_3_set?
        # Read until we end decompressing the deflate data,
        # which has an unknown size
      else
        io = IO::Sized.new(io, compressed_size) unless is_sized
      end

      io = Compress::Deflate::Reader.new(io)
    else
      raise "Unsupported compression method: #{compression_method}"
    end

    io
  end

  protected def bit_3_set?
    (general_purpose_bit_flag & 0b1000) != 0
  end

  # date is:
  # - 7 bits for year (0 is 1980)
  # - 4 bits for month
  # - 5 bits for day
  # time is:
  # - 5 bits for hour
  # - 6 bits for minute
  # - 5 bits for seconds (0..29), precision of two seconds

  private def from_dos(date, time)
    year = 1980 + (date >> 9)
    month = (date >> 5) & 0b1111
    day = date & 0b11111

    hour = time >> 11
    minute = (time >> 5) & 0b111111
    second = (time & 0b11111) * 2

    Time.utc(year.to_i, month.to_i, day.to_i, hour.to_i, minute.to_i, second.to_i)
  end

  private def to_dos
    date = ((@time.year - 1980) << 9) |
           (@time.month << 5) |
           @time.day

    time = (@time.hour << 11) |
           (@time.minute << 5) |
           (@time.second // 2)

    {date.to_u16, time.to_u16}
  end

  private def read(io, type)
    io.read_bytes(type, IO::ByteFormat::LittleEndian)
  end

  private def write(io, value)
    io.write_bytes(value, IO::ByteFormat::LittleEndian)
  end
end
