//
//  Archive+Writing.swift
//  Spot
//
//  Created by Shawn Clovie on 7/16/2018.
//  Copyright © 2018 Shawn Clovie. All rights reserved.
//

import Foundation
import Spot

extension ZipArchive {
	private enum ModifyOperation {
		case remove, add
		
		var changeCount: Int8 {
			switch self {
			case .add:		return 1
			case .remove:	return -1
			}
		}
	}

	/// Write files, directories or symlinks to the receiver.
	///
	/// - Parameters:
	///   - path: The path that is used to identify an `Entry` within the `Archive` file.
	///   - entryPath: The base path of the `Entry` to add. The entryPath combined with `path` must form a fully qualified file URL.
	///   - level: Indicates the compression method that should be applied to `Entry`.
	///   - bufferSize: The maximum size of the write buffer and the compression buffer (if needed).
	///   - progress: A progress object that can be used to track or cancel the add operation.
	/// - Throws: An error if the source file cannot be read or the receiver is not writable.
	public func addEntry(at path: URL,
						 entryPath: String = "",
						 by level: ZipArchiveLevel = .store,
						 bufferSize: UInt32 = ZipWriteChunkSize,
						 progress: Progress? = nil) throws {
		let fileManager = FileManager()
		guard fileManager.fileExists(atPath: path.path) else {
			throw AttributedError(.fileNotFound)
		}
		guard fileManager.isReadableFile(atPath: path.path) else {
			throw AttributedError(AttributedError.Source.privilegeLimited)
		}
		let entryPath = entryPath.isEmpty ? path.lastPathComponent : entryPath
		let type = try ZipArchive.typeForItem(at: path, with: fileManager)
		let modDate = try fileManager.fileModificationDateTimeForItem(at: path)
		let uncompressedSize = type == .directory ? 0 : try fileManager.fileSizeForItem(at: path)
		let permissions = try fileManager.permissionsForItem(at: path)
		var provider: ZipDataProvider
		switch type {
		case .file:
			let entryFileSystemRepresentation = fileManager.fileSystemRepresentation(withPath: path.path)
			let entryFile: UnsafeMutablePointer<FILE> = fopen(entryFileSystemRepresentation, "rb")
			defer {
				fclose(entryFile)
			}
			provider = { _, _ in try Data.readChunk(of: Int(bufferSize), from: entryFile)}
			try self.addEntry(with: entryPath, type: type,
							  uncompressedSize: uncompressedSize,
							  modificationDate: modDate,
							  permissions: permissions,
							  by: level, bufferSize: bufferSize,
							  progress: progress, provider: provider)
		case .directory:
			provider = { _, _ in Data()}
			try self.addEntry(with: entryPath.hasSuffix("/") ? entryPath : entryPath + "/",
							  type: type, uncompressedSize: uncompressedSize,
							  modificationDate: modDate, permissions: permissions,
							  by: level,
							  bufferSize: bufferSize,
							  progress: progress, provider: provider)
		case .symlink:
			provider = { _, _ -> Data in
				let fileManager = FileManager()
				let linkDestination = try fileManager.destinationOfSymbolicLink(atPath: path.path)
				let linkFileSystemRepresentation = fileManager.fileSystemRepresentation(withPath: linkDestination)
				let linkLength = Int(strlen(linkFileSystemRepresentation))
				let linkBuffer = UnsafeBufferPointer(start: linkFileSystemRepresentation, count: linkLength)
				return Data.init(buffer: linkBuffer)
			}
			try self.addEntry(with: entryPath, type: type,
							  uncompressedSize: uncompressedSize,
							  modificationDate: modDate,
							  permissions: permissions,
							  by: level,
							  bufferSize: bufferSize,
							  progress: progress, provider: provider)
		}
	}

	/// Write files, directories or symlinks to the receiver.
	///
	/// - Parameters:
	///   - path: The path that is used to identify an `Entry` within the `Archive` file.
	///   - type: Indicates the `Entry.EntryType` of the added content.
	///   - uncompressedSize: The uncompressed size of the data that is going to be added with `provider`.
	///   - modificationDate: A `Date` describing the file modification date of the `Entry`.
	///                       Default is the current `Date`.
	///   - permissions: POSIX file permissions for the `Entry`.
	///                  Default is `0`o`644` for files and symlinks and `0`o`755` for directories.
	///   - level: Indicates the compression method that should be applied to `Entry`.
	///   - bufferSize: The maximum size of the write buffer and the compression buffer (if needed).
	///   - progress: A progress object that can be used to track or cancel the add operation.
	///   - provider: A closure that accepts a position and a chunk size. Returns a `Data` chunk.
	/// - Throws: An error if the source data is invalid or the receiver is not writable.
	public func addEntry(with path: String,
						 type: ZipEntry.EntryType,
						 uncompressedSize: UInt32,
						 modificationDate: Date = Date(),
						 permissions: UInt16? = nil,
						 by level: ZipArchiveLevel = .store,
						 bufferSize: UInt32 = ZipWriteChunkSize,
						 progress: Progress? = nil,
						 provider: ZipDataProvider) throws {
		guard accessMode != .read else {
			throw AttributedError(.fileNotWritable)
		}
		progress?.totalUnitCount = type == .directory ? ZipDirectoryUnitCount : Int64(uncompressedSize)
		let endOfCentralDirRecord = endOfCentralDirectoryRecord
		let startOfCD = Int(endOfCentralDirRecord.offsetToStartOfCentralDirectory)
		fseek(archiveFile, startOfCD, SEEK_SET)
		let existingCentralDirData = try Data.readChunk(of: Int(endOfCentralDirRecord.sizeOfCentralDirectory), from: archiveFile)
		fseek(archiveFile, startOfCD, SEEK_SET)
		let localFileHeaderStart = ftell(archiveFile)
		defer {
			fflush(archiveFile)
		}
		do {
			let fileManager = FileManager()
			let header0 = try writeLocalFileHeader(path: path, by: level, size: (uncompressedSize, 0), checksum: 0, modification: modificationDate, fileManager: fileManager)
			let (written, checksum) = try writeEntry(header0, of: type, by: level, bufferSize: bufferSize, progress: progress, provider: provider)
			let startOfCD = ftell(archiveFile)
			fseek(archiveFile, localFileHeaderStart, SEEK_SET)
			// Write the local file header a second time. Now with compressedSize (if applicable) and a valid checksum.
			let headerLast = try writeLocalFileHeader(path: path, by: level, size: (uncompressedSize, written), checksum: checksum, modification: modificationDate, fileManager: fileManager)
			fseek(archiveFile, startOfCD, SEEK_SET)
			_ = try existingCentralDirData.write(to: archiveFile)
			let permissions = permissions
				?? (type == .directory ? ZipEntryDefaultDirectoryPermissions : ZipEntryDefaultFilePermissions)
			let externalAttributes = type.entryExternalFileAttributes(permissions: permissions)
			let centralDir = try writeCentralDirectoryStructure(headerLast, relativeOffset: UInt32(localFileHeaderStart), externalFileAttributes: externalAttributes)
			if startOfCD > UINT32_MAX {
				throw AttributedError(ZipErrorSource.invalidStartOfCentralDirectoryOffset)
			}
			endOfCentralDirectoryRecord = try writeEndOfCentralDirectory(centralDir, startOfCentralDirectory: UInt32(startOfCD), .add)
		} catch let err as AttributedError {
			if err.source == .cancelled {
				try rollback(localFileHeaderStart, existingCentralDirData, endOfCentralDirRecord)
			}
			throw err
		}
	}

	/// Remove a ZIP `Entry` from the receiver.
	///
	/// - Parameters:
	///   - entry: The `Entry` to remove.
	///   - bufferSize: The maximum size for the read and write buffers used during removal.
	///   - progress: A progress object that can be used to track or cancel the remove operation.
	/// - Throws: An error if the `Entry` is malformed or the receiver is not writable.
	public func remove(_ entry: ZipEntry,
					   bufferSize: UInt32 = ZipReadChunkSize,
					   progress: Progress? = nil) throws {
		let uniqueString = ProcessInfo.processInfo.globallyUniqueString
		let tempArchiveURL =  URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(uniqueString)
		let archive = try ZipArchive(url: tempArchiveURL, for: .create)
		progress?.totalUnitCount = totalUnitCount(removing: entry)
		var centralDirectoryData = Data()
		var offset = 0
		for curEntry in self {
			let curStructure = curEntry.centralDirectoryStructure
			if curEntry != entry {
				let entryStart = Int(curEntry.centralDirectoryStructure.relativeOffsetOfLocalHeader)
				fseek(archiveFile, entryStart, SEEK_SET)
				_ = try Data.consumePart(of: Int(curEntry.localSize), chunkSize: Int(bufferSize), provider: { (_, chunkSize) in
					if progress?.isCancelled == true {
						throw AttributedError(.cancelled)
					}
					return try Data.readChunk(of: Int(chunkSize), from: archiveFile)
				}, consumer: {
					_ = try $0.write(to: archive.archiveFile)
					progress?.completedUnitCount += Int64($0.count)
				})
				let offsetStructure = ZipEntry.CentralDirectoryStructure(from: curStructure, offset: UInt32(offset))
				centralDirectoryData.append(offsetStructure.data)
			} else {
				offset = curEntry.localSize
			}
		}
		let startOfCentralDirectory = ftell(archive.archiveFile)
		_ = try centralDirectoryData.write(to: archive.archiveFile)
		archive.endOfCentralDirectoryRecord = endOfCentralDirectoryRecord
		let record = try archive.writeEndOfCentralDirectory(entry.centralDirectoryStructure, startOfCentralDirectory: UInt32(startOfCentralDirectory), .remove)
		archive.endOfCentralDirectoryRecord = record
		endOfCentralDirectoryRecord = record
		fflush(archive.archiveFile)
		try replaceCurrentArchiveWithArchive(at: archive.url)
	}

	// MARK: - Helpers

	private func writeLocalFileHeader(path: String,
									  by level: ZipArchiveLevel,
									  size: (uncompressed: UInt32, compressed: UInt32),
									  checksum: CRC32,
									  modification: Date,
									  fileManager: FileManager = .init()) throws -> ZipEntry.LocalFileHeader {
		let fsRepresentation = fileManager.fileSystemRepresentation(withPath: path)
		let nameLen = strlen(fsRepresentation)
		let nameBuf = UnsafeBufferPointer(start: fsRepresentation, count: nameLen)
		let header = ZipEntry.LocalFileHeader(
			versionNeededToExtract: UInt16(20),
			generalPurposeBitFlag: UInt16(2048),
			compressionMethod: level.rawValue,
			lastModFileTime: modification.zipFileModificationTime,
			lastModFileDate: modification.zipFileModificationDate,
			crc32: checksum,
			compressedSize: size.compressed,
			uncompressedSize: size.uncompressed,
			fileNameLength: UInt16(nameLen),
			extraFieldLength: UInt16(0),
			fileNameData: Data(buffer: nameBuf),
			extraFieldData: Data())
		_ = try header.data.write(to: archiveFile)
		return header
	}

	private func writeEntry(_ header: ZipEntry.LocalFileHeader,
							of type: ZipEntry.EntryType,
							by level: ZipArchiveLevel,
							bufferSize: UInt32, progress: Progress? = nil,
							provider: ZipDataProvider) throws -> (sizeWritten: UInt32, crc32: CRC32) {
		var checksum = CRC32(0)
		var sizeWritten = UInt32(0)
		switch type {
		case .file:
			switch level {
			case .store:
				(sizeWritten, checksum) = try writeUncompressed(size: header.uncompressedSize, bufferSize: bufferSize, progress: progress, provider: provider)
			case .deflate:
				(sizeWritten, checksum) = try writeCompressed(size: header.uncompressedSize, bufferSize: bufferSize, progress: progress, provider: provider)
			}
		case .directory:
			_ = try provider(0, 0)
			if let progress = progress {
				progress.completedUnitCount = progress.totalUnitCount
			}
		case .symlink:
			(sizeWritten, checksum) = try writeSymbolicLink(size: header.uncompressedSize, provider: provider)
			if let progress = progress {
				progress.completedUnitCount = progress.totalUnitCount
			}
		}
		return (sizeWritten, checksum)
	}

	private func writeUncompressed(size: UInt32,
								   bufferSize: UInt32,
								   progress: Progress? = nil,
								   provider: ZipDataProvider) throws -> (sizeWritten: UInt32, checksum: CRC32) {
		var position = 0
		var sizeWritten = 0
		var checksum = CRC32(0)
		while position < size {
			if progress?.isCancelled == true {
				throw AttributedError(.cancelled)
			}
			let readSize = (Int(size) - position) >= bufferSize ? Int(bufferSize) : (Int(size) - position)
			let entryChunk = try provider(Int(position), Int(readSize))
			checksum = entryChunk.crc32(checksum: checksum)
			sizeWritten += try entryChunk.write(to: archiveFile)
			position += Int(bufferSize)
			progress?.completedUnitCount = Int64(sizeWritten)
		}
		return (UInt32(sizeWritten), checksum)
	}

	private func writeCompressed(size: UInt32,
								 bufferSize: UInt32,
								 progress: Progress? = nil,
								 provider: ZipDataProvider) throws -> (sizeWritten: UInt32, checksum: CRC32) {
		let data = try provider(0, Int(size))
			.spot.deflated()
		let written = try data.write(to: archiveFile)
		return (UInt32(written), data.crc32(checksum: 0))
	}

	private func writeSymbolicLink(size: UInt32, provider: ZipDataProvider) throws -> (sizeWritten: UInt32, checksum: CRC32) {
		let linkData = try provider(0, Int(size))
		let checksum = linkData.crc32(checksum: 0)
		let sizeWritten = try linkData.write(to: archiveFile)
		return (UInt32(sizeWritten), checksum)
	}

	private func writeCentralDirectoryStructure(_ header: ZipEntry.LocalFileHeader, relativeOffset: UInt32, externalFileAttributes: UInt32) throws -> ZipEntry.CentralDirectoryStructure {
		let structure = ZipEntry.CentralDirectoryStructure(from: header, fileAttributes: externalFileAttributes, relativeOffset: relativeOffset)
		_ = try structure.data.write(to: archiveFile)
		return structure
	}

	private func writeEndOfCentralDirectory(_ structure: ZipEntry.CentralDirectoryStructure,
											startOfCentralDirectory: UInt32,
											_ operation: ModifyOperation) throws -> EndOfCentralDirectoryRecord {
		var record = endOfCentralDirectoryRecord
		let countChange = operation.changeCount
		let dataLength = structure.extraFieldLength + structure.fileNameLength + structure.fileCommentLength
		let updatedSize = record.sizeOfCentralDirectory + UInt32(countChange) * (UInt32(dataLength) + UInt32(ZipEntry.CentralDirectoryStructure.size))
		record = EndOfCentralDirectoryRecord(
			record: record,
			numberOfEntriesOnDisk: record.totalNumberOfEntriesOnDisk + UInt16(countChange),
			numberOfEntriesInCentralDirectory: record.totalNumberOfEntriesInCentralDirectory + UInt16(countChange),
			updatedSizeOfCentralDirectory: updatedSize,
			startOfCentralDirectory: startOfCentralDirectory)
		_ = try record.data.write(to: archiveFile)
		return record
	}

	private func rollback(_ localFileHeaderStart: Int,
						  _ existingCentralDirectoryData: Data,
						  _ record: EndOfCentralDirectoryRecord) throws {
		fflush(archiveFile)
		ftruncate(fileno(archiveFile), off_t(localFileHeaderStart))
		fseek(archiveFile, localFileHeaderStart, SEEK_SET)
		_ = try existingCentralDirectoryData.write(to: archiveFile)
		_ = try record.data.write(to: archiveFile)
	}

	private func replaceCurrentArchiveWithArchive(at url: URL) throws {
		fclose(archiveFile)
		let fileManager = FileManager()
		#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
		_ = try fileManager.replaceItemAt(self.url, withItemAt: url)
		#else
		_ = try fileManager.removeItem(at: self.url)
		_ = try fileManager.moveItem(at: url, to: self.url)
		#endif
		let fileSystemRepresentation = fileManager.fileSystemRepresentation(withPath: self.url.path)
		archiveFile = fopen(fileSystemRepresentation, "rb+")
	}
}
