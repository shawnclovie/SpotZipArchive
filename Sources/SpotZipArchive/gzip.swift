import Foundation
#if os(Linux)
import zlibLinux
#else
import zlib
#endif

public enum GZip {

	/// An unsigned 32-Bit Integer representing a checksum.
	public typealias CRC32 = UInt32

	/// Zip level whose rawValue is based on the zlib's constants.
	public struct Level: RawRepresentable {
		
		/// Zip level in the range of `0` (no compression) to `9` (maximum compression).
		public let rawValue: Int32
		
		public static let store = Level(Z_NO_COMPRESSION)
		public static let quickly = Level(Z_BEST_SPEED)
		public static let smaller = Level(Z_BEST_COMPRESSION)
		public static let `default` = Level(Z_DEFAULT_COMPRESSION)
		
		public init(rawValue: Int32) {
			self.rawValue = rawValue
		}
		
		public init(_ rawValue: Int32) {
			self.rawValue = rawValue
		}
	}
	
	/// Whether the data is compressed in gzip format (by check magic number).
	public static func isDefalted(_ data: Data) -> Bool {
		data.starts(with: [0x1f, 0x8b])
	}
	
	/// Create a new `Data` object by compressing the receiver using zlib.
	///
	/// - Parameter level: Compression level.
	/// - throws: `ZipError`
	/// - returns: Zipped data
	public static func deflated(_ data: Data, level: Level) throws -> Data {
		guard let contiguousData = data.withUnsafeBytes({ (bytes: UnsafeRawBufferPointer) -> Data? in
			guard let bytes = bytes.baseAddress else {return nil}
			return Data(bytes: UnsafePointer(OpaquePointer(bytes)), count: data.count)
		}), !contiguousData.isEmpty else {
			return Data()
		}
		var stream = makeZStream(for: contiguousData)
		let status = deflateInit2_(&stream, level.rawValue, Z_DEFLATED, MAX_WBITS + 16, MAX_MEM_LEVEL, Z_DEFAULT_STRATEGY, ZLIB_VERSION, streamSize)
		guard status == Z_OK else {
			// deflateInit2 returns:
			// Z_VERSION_ERROR  The zlib library version is incompatible with the version assumed by the caller.
			// Z_MEM_ERROR      There was not enough memory.
			// Z_STREAM_ERROR   A parameter is invalid.
			throw ZipError(gzip: status, stream)
		}
		var data = Data(capacity: Int(chunkSize))
		while stream.avail_out == 0 {
			if Int(stream.total_out) >= data.count {
				data.count += Int(chunkSize)
			}
			let len = data.count
			data.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
				guard let ptr = bytes.baseAddress else {return}
				let advanced = ptr.advanced(by: Int(stream.total_out))
				stream.next_out = UnsafeMutablePointer(OpaquePointer(advanced))
				stream.avail_out = uInt(len) - uInt(stream.total_out)
				deflate(&stream, Z_FINISH)
			}
		}
		deflateEnd(&stream)
		data.count = Int(stream.total_out)
		return data
	}
	
	/// Create a new `Data` object by decompressing the receiver using zlib.
	/// - Throws: `ZipError`
	/// - Returns: Unzipped data
	public static func inflated(_ data: Data) throws -> Data {
		guard let contiguousData = data.withUnsafeBytes({ (bytes: UnsafeRawBufferPointer) -> Data? in
			guard let bytes = bytes.baseAddress else {return nil}
			return Data(bytes: UnsafePointer(OpaquePointer(bytes)), count: data.count)
		}), !contiguousData.isEmpty else {
			return Data()
		}
		var stream = makeZStream(for: contiguousData)
		var status = inflateInit2_(&stream, MAX_WBITS + 32, ZLIB_VERSION, streamSize)
		guard status == Z_OK else {
			// inflateInit2 returns:
			// Z_VERSION_ERROR   The zlib library version is incompatible with the version assumed by the caller.
			// Z_MEM_ERROR       There was not enough memory.
			// Z_STREAM_ERROR    A parameters are invalid.
			throw ZipError(gzip: status, stream)
		}
		var data = Data(capacity: contiguousData.count * 2)
		repeat {
			if Int(stream.total_out) >= data.count {
				data.count += contiguousData.count / 2
			}
			let len = data.count
			data.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
				guard let ptr = bytes.baseAddress else {return}
				let advanced = ptr.advanced(by: Int(stream.total_out))
				stream.next_out = UnsafeMutablePointer(OpaquePointer(advanced))
				stream.avail_out = uInt(len) - uInt(stream.total_out)
				status = inflate(&stream, Z_SYNC_FLUSH)
			}
		} while status == Z_OK
		guard inflateEnd(&stream) == Z_OK && status == Z_STREAM_END else {
			// inflate returns:
			// Z_DATA_ERROR   The input data was corrupted (input stream not conforming to the zlib format or incorrect check value).
			// Z_STREAM_ERROR The stream structure was inconsistent (for example if next_in or next_out was NULL).
			// Z_MEM_ERROR    There was not enough memory.
			// Z_BUF_ERROR    No progress is possible or there was not enough room in the output buffer when Z_FINISH is used.
			throw ZipError(gzip: status, stream)
		}
		data.count = Int(stream.total_out)
		return data
	}
	
	private static func makeZStream(for data: Data) -> z_stream {
		var stream = z_stream()
		data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
			guard let bytes = bytes.baseAddress else {return}
			stream.next_in = UnsafeMutablePointer(OpaquePointer(bytes))
		}
		stream.avail_in = uint(data.count)
		return stream
	}

	public static let chunkSize = UInt32(2 ^ 14)
	private static let streamSize = Int32(MemoryLayout<z_stream>.size)

	/// Calculates the `CRC32` checksum of the receiver.
	///
	/// - Parameter checksum: The starting seed, can be 0.
	/// - Returns: The checksum calcualted from the bytes of the receiver and the starting seed.
	static func crc32(_ data: Data, checksum: CRC32) -> CRC32 {
		// The typecast is necessary on 32-bit platforms because of
		// https://bugs.swift.org/browse/SR-1774
		let mask = 0xffffffff as UInt32
		let bufferSize = data.count / MemoryLayout<UInt8>.size
		var result = checksum ^ mask
		data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
			let bins = stride(from: 0, to: bufferSize, by: 256)
			for bin in bins {
				for binIndex in 0..<256 {
					let byteIndex = bin + binIndex
					guard byteIndex < bufferSize else {break}
					let byte = bytes[byteIndex]
					let index = Int((result ^ UInt32(byte)) & 0xff)
					result = (result >> 8) ^ crcTable[index]
				}
			}
		}
		return result ^ mask
	}
	
	@discardableResult
	static func write(_ data: Data, to file: UnsafeMutablePointer<FILE>) throws -> Int {
		var sizeWritten = 0
		data.withUnsafeBytes{ (bytes: UnsafeRawBufferPointer) in
			guard let ptr = bytes.baseAddress else {return}
			sizeWritten = fwrite(ptr, 1, data.count, file)
		}
		let error = ferror(file)
		if error > 0 {
			throw ZipError(.fileNotAccessable, userInfo: ["code": error])
		}
		return sizeWritten
	}
	
	static func scanValue<T>(_ data: Data, start: Int) -> T {
		data.subdata(in: start..<start + MemoryLayout<T>.size)
			.withUnsafeBytes{ (bytes: UnsafeRawBufferPointer) in
				bytes.bindMemory(to: T.self).baseAddress!.pointee
		}
	}
	
	static func readStruct<T>(from file: UnsafeMutablePointer<FILE>, at offset: Int) -> T? where T: DataSerializable {
		fseek(file, offset, SEEK_SET)
		guard let data = try? readChunk(of: T.size, from: file) else {
			return nil
		}
		let structure = T(data: data, additionalDataProvider: { (additionalDataSize) -> Data in
			return try readChunk(of: additionalDataSize, from: file)
		})
		return structure
	}
	
	@discardableResult
	static func consumePart(of size: Int,
							chunkSize: Int,
							skipCRC32: Bool = false,
							provider: ZipDataProvider, consumer: ZipDataConsumer) throws -> CRC32 {
		let readInOneChunk = (size < chunkSize)
		var chunkSize = readInOneChunk ? size : chunkSize
		var checksum = CRC32(0)
		var bytesRead = 0
		while bytesRead < size {
			let remainingSize = size - bytesRead
			chunkSize = Swift.min(remainingSize, chunkSize)
			let data = try provider(bytesRead, chunkSize)
			try consumer(data)
			if !skipCRC32 {
				checksum = crc32(data, checksum: checksum)
			}
			bytesRead += chunkSize
		}
		return checksum
	}
	
	static func readChunk(of size: Int, from file: UnsafeMutablePointer<FILE>) throws -> Data {
		#if swift(>=4.1)
		let bytes = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 1)
		#else
		let bytes = UnsafeMutableRawPointer.allocate(bytes: size, alignedTo: 1)
		#endif
		let bytesRead = fread(bytes, 1, size, file)
		let error = ferror(file)
		if error > 0 {
			throw ZipError(.fileNotAccessable)
		}
		return Data(bytesNoCopy: bytes, count: bytesRead, deallocator: Data.Deallocator.free)
	}
}

protocol DataSerializable {
	static var size: Int {get}
	var data: Data {get}
	init?(data: Data, additionalDataProvider: (Int) throws -> Data)
}

/// The lookup table used to calculate `CRC32` checksums.
private let crcTable: [UInt32] = [
	0x00000000, 0x77073096, 0xee0e612c, 0x990951ba, 0x076dc419,
	0x706af48f, 0xe963a535, 0x9e6495a3, 0x0edb8832, 0x79dcb8a4,
	0xe0d5e91e, 0x97d2d988, 0x09b64c2b, 0x7eb17cbd, 0xe7b82d07,
	0x90bf1d91, 0x1db71064, 0x6ab020f2, 0xf3b97148, 0x84be41de,
	0x1adad47d, 0x6ddde4eb, 0xf4d4b551, 0x83d385c7, 0x136c9856,
	0x646ba8c0, 0xfd62f97a, 0x8a65c9ec, 0x14015c4f, 0x63066cd9,
	0xfa0f3d63, 0x8d080df5, 0x3b6e20c8, 0x4c69105e, 0xd56041e4,
	0xa2677172, 0x3c03e4d1, 0x4b04d447, 0xd20d85fd, 0xa50ab56b,
	0x35b5a8fa, 0x42b2986c, 0xdbbbc9d6, 0xacbcf940, 0x32d86ce3,
	0x45df5c75, 0xdcd60dcf, 0xabd13d59, 0x26d930ac, 0x51de003a,
	0xc8d75180, 0xbfd06116, 0x21b4f4b5, 0x56b3c423, 0xcfba9599,
	0xb8bda50f, 0x2802b89e, 0x5f058808, 0xc60cd9b2, 0xb10be924,
	0x2f6f7c87, 0x58684c11, 0xc1611dab, 0xb6662d3d, 0x76dc4190,
	0x01db7106, 0x98d220bc, 0xefd5102a, 0x71b18589, 0x06b6b51f,
	0x9fbfe4a5, 0xe8b8d433, 0x7807c9a2, 0x0f00f934, 0x9609a88e,
	0xe10e9818, 0x7f6a0dbb, 0x086d3d2d, 0x91646c97, 0xe6635c01,
	0x6b6b51f4, 0x1c6c6162, 0x856530d8, 0xf262004e, 0x6c0695ed,
	0x1b01a57b, 0x8208f4c1, 0xf50fc457, 0x65b0d9c6, 0x12b7e950,
	0x8bbeb8ea, 0xfcb9887c, 0x62dd1ddf, 0x15da2d49, 0x8cd37cf3,
	0xfbd44c65, 0x4db26158, 0x3ab551ce, 0xa3bc0074, 0xd4bb30e2,
	0x4adfa541, 0x3dd895d7, 0xa4d1c46d, 0xd3d6f4fb, 0x4369e96a,
	0x346ed9fc, 0xad678846, 0xda60b8d0, 0x44042d73, 0x33031de5,
	0xaa0a4c5f, 0xdd0d7cc9, 0x5005713c, 0x270241aa, 0xbe0b1010,
	0xc90c2086, 0x5768b525, 0x206f85b3, 0xb966d409, 0xce61e49f,
	0x5edef90e, 0x29d9c998, 0xb0d09822, 0xc7d7a8b4, 0x59b33d17,
	0x2eb40d81, 0xb7bd5c3b, 0xc0ba6cad, 0xedb88320, 0x9abfb3b6,
	0x03b6e20c, 0x74b1d29a, 0xead54739, 0x9dd277af, 0x04db2615,
	0x73dc1683, 0xe3630b12, 0x94643b84, 0x0d6d6a3e, 0x7a6a5aa8,
	0xe40ecf0b, 0x9309ff9d, 0x0a00ae27, 0x7d079eb1, 0xf00f9344,
	0x8708a3d2, 0x1e01f268, 0x6906c2fe, 0xf762575d, 0x806567cb,
	0x196c3671, 0x6e6b06e7, 0xfed41b76, 0x89d32be0, 0x10da7a5a,
	0x67dd4acc, 0xf9b9df6f, 0x8ebeeff9, 0x17b7be43, 0x60b08ed5,
	0xd6d6a3e8, 0xa1d1937e, 0x38d8c2c4, 0x4fdff252, 0xd1bb67f1,
	0xa6bc5767, 0x3fb506dd, 0x48b2364b, 0xd80d2bda, 0xaf0a1b4c,
	0x36034af6, 0x41047a60, 0xdf60efc3, 0xa867df55, 0x316e8eef,
	0x4669be79, 0xcb61b38c, 0xbc66831a, 0x256fd2a0, 0x5268e236,
	0xcc0c7795, 0xbb0b4703, 0x220216b9, 0x5505262f, 0xc5ba3bbe,
	0xb2bd0b28, 0x2bb45a92, 0x5cb36a04, 0xc2d7ffa7, 0xb5d0cf31,
	0x2cd99e8b, 0x5bdeae1d, 0x9b64c2b0, 0xec63f226, 0x756aa39c,
	0x026d930a, 0x9c0906a9, 0xeb0e363f, 0x72076785, 0x05005713,
	0x95bf4a82, 0xe2b87a14, 0x7bb12bae, 0x0cb61b38, 0x92d28e9b,
	0xe5d5be0d, 0x7cdcefb7, 0x0bdbdf21, 0x86d3d2d4, 0xf1d4e242,
	0x68ddb3f8, 0x1fda836e, 0x81be16cd, 0xf6b9265b, 0x6fb077e1,
	0x18b74777, 0x88085ae6, 0xff0f6a70, 0x66063bca, 0x11010b5c,
	0x8f659eff, 0xf862ae69, 0x616bffd3, 0x166ccf45, 0xa00ae278,
	0xd70dd2ee, 0x4e048354, 0x3903b3c2, 0xa7672661, 0xd06016f7,
	0x4969474d, 0x3e6e77db, 0xaed16a4a, 0xd9d65adc, 0x40df0b66,
	0x37d83bf0, 0xa9bcae53, 0xdebb9ec5, 0x47b2cf7f, 0x30b5ffe9,
	0xbdbdf21c, 0xcabac28a, 0x53b39330, 0x24b4a3a6, 0xbad03605,
	0xcdd70693, 0x54de5729, 0x23d967bf, 0xb3667a2e, 0xc4614ab8,
	0x5d681b02, 0x2a6f2b94, 0xb40bbe37, 0xc30c8ea1, 0x5a05df1b,
	0x2d02ef8d]
