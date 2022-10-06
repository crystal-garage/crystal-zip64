# Supported compression methods in the current implementation.
enum Compress::Zip64::CompressionMethod : UInt16
  STORED   = 0
  DEFLATED = 8
end
