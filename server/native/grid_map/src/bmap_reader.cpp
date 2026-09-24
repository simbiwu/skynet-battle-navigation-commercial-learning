// 职责：逐字段读取并验证 Little Endian BMAP V1，校验成功后创建 GridMap。
// 边界：Server Asset Loader；磁盘数据在通过尺寸、CRC 和版本检查前一律不可信。
// 输入/输出：文件字节 -> BMapMetadata、NavCell 数组和 immutable GridMap。
// 生命周期：临时文件缓冲只在 Read 内存活；返回地图由 shared_ptr 管理。
// 不负责：不使用 struct cast、不注册地图、不修复损坏资产。
#include "bmap_reader.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <fstream>
#include <limits>
#include <sstream>
#include <utility>
#include <vector>

namespace battle_nav {
namespace {

constexpr std::size_t kHeaderCrcOffset = 52; // Header CRC 字段相对文件起点的 byte offset。

// 从 bytes[0..1] 读取一个无符号 Little Endian 16-bit 值；调用方保证至少 2 bytes。
std::uint16_t ReadU16Le(const std::uint8_t* bytes) noexcept {
    return static_cast<std::uint16_t>(bytes[0]) |
        static_cast<std::uint16_t>(bytes[1]) << 8;
}

// 从 bytes[0..3] 读取一个无符号 Little Endian 32-bit 值；调用方保证至少 4 bytes。
std::uint32_t ReadU32Le(const std::uint8_t* bytes) noexcept {
    return static_cast<std::uint32_t>(bytes[0]) |
        static_cast<std::uint32_t>(bytes[1]) << 8 |
        static_cast<std::uint32_t>(bytes[2]) << 16 |
        static_cast<std::uint32_t>(bytes[3]) << 24;
}

// 读取 Little Endian 32-bit 位型并按补码解释为有符号值。
std::int32_t ReadI32Le(const std::uint8_t* bytes) noexcept {
    return static_cast<std::int32_t>(ReadU32Le(bytes));
}

// 把 value 写入 bytes[0..3]，用于计算 Header CRC 前临时清零 CRC 字段。
void WriteU32Le(std::uint8_t* bytes, std::uint32_t value) noexcept {
    bytes[0] = static_cast<std::uint8_t>(value);
    bytes[1] = static_cast<std::uint8_t>(value >> 8);
    bytes[2] = static_cast<std::uint8_t>(value >> 16);
    bytes[3] = static_cast<std::uint8_t>(value >> 24);
}

// 计算 [bytes, bytes+size) 的 reflected CRC-32/ISO-HDLC；与 Unity Writer 参数一致。
// 时间复杂度 O(size*8)，不分配内存，不读取范围外字节。
std::uint32_t Crc32(const std::uint8_t* bytes, std::size_t size) noexcept {
    std::uint32_t crc = 0xffffffffu;
    for (std::size_t i = 0; i < size; ++i) {
        crc ^= bytes[i];
        for (int bit = 0; bit < 8; ++bit) {
            crc = (crc & 1u) != 0
                ? 0xedb88320u ^ (crc >> 1)
                : crc >> 1;
        }
    }
    return crc ^ 0xffffffffu;
}

// 生成长度校验失败的诊断文字；expected/actual 的单位由调用点保持一致。
std::string SizeDetail(
    std::uint64_t expected,
    std::uint64_t actual) {
    std::ostringstream stream;
    stream << "expected=" << expected << " actual=" << actual;
    return stream.str();
}

}  // namespace

NavResult<std::shared_ptr<const GridMap>> BMapReader::Read(
    const std::string& path) {
    std::ifstream stream(path, std::ios::binary | std::ios::ate);
    if (!stream) {
        return NavResult<std::shared_ptr<const GridMap>>::Failure(
            NavError::kIoError,
            "cannot open: " + path);
    }

    const std::streamoff end = stream.tellg();
    if (end < 0) {
        return NavResult<std::shared_ptr<const GridMap>>::Failure(
            NavError::kIoError,
            "tellg failed: " + path);
    }
    const std::uint64_t file_size = static_cast<std::uint64_t>(end);
    if (file_size < kBMapHeaderSize) {
        return NavResult<std::shared_ptr<const GridMap>>::Failure(
            NavError::kTruncated,
            SizeDetail(kBMapHeaderSize, file_size));
    }
    if (file_size > std::numeric_limits<std::size_t>::max()) {
        return NavResult<std::shared_ptr<const GridMap>>::Failure(
            NavError::kSizeOverflow,
            "file larger than addressable memory");
    }

    stream.seekg(0, std::ios::beg);
    std::vector<std::uint8_t> file(static_cast<std::size_t>(file_size));
    stream.read(
        reinterpret_cast<char*>(file.data()),
        static_cast<std::streamsize>(file.size()));
    if (!stream || static_cast<std::size_t>(stream.gcount()) != file.size()) {
        return NavResult<std::shared_ptr<const GridMap>>::Failure(
            NavError::kTruncated,
            "short read: " + path);
    }

    if (file[0] != 'B' || file[1] != 'M' ||
        file[2] != 'A' || file[3] != 'P') {
        return NavResult<std::shared_ptr<const GridMap>>::Failure(
            NavError::kBadMagic,
            "magic is not BMAP");
    }

    const std::uint16_t format_version = ReadU16Le(file.data() + 4);
    const std::uint16_t header_size = ReadU16Le(file.data() + 6);
    if (format_version != kBMapFormatVersion) {
        return NavResult<std::shared_ptr<const GridMap>>::Failure(
            NavError::kUnsupportedVersion,
            "format_version=" + std::to_string(format_version));
    }
    if (header_size != kBMapHeaderSize) {
        return NavResult<std::shared_ptr<const GridMap>>::Failure(
            NavError::kInvalidHeaderSize,
            "header_size=" + std::to_string(header_size));
    }

    BMapMetadata metadata;
    metadata.map_id = ReadU32Le(file.data() + 8);
    metadata.map_version = ReadU32Le(file.data() + 12);
    metadata.width = ReadU32Le(file.data() + 16);
    metadata.height = ReadU32Le(file.data() + 20);
    metadata.cell_size_mm = ReadU32Le(file.data() + 24);
    metadata.origin_x_mm = ReadI32Le(file.data() + 28);
    metadata.origin_z_mm = ReadI32Le(file.data() + 32);
    metadata.flags = ReadU32Le(file.data() + 36);
    const std::uint16_t cell_stride = ReadU16Le(file.data() + 40);
    const std::uint16_t reserved0 = ReadU16Le(file.data() + 42);
    const std::uint32_t payload_size = ReadU32Le(file.data() + 44);
    const std::uint32_t expected_payload_crc = ReadU32Le(file.data() + 48);
    const std::uint32_t expected_header_crc = ReadU32Le(file.data() + 52);

    if (metadata.map_id == 0 || metadata.map_version == 0 ||
        metadata.width == 0 || metadata.height == 0 ||
        metadata.cell_size_mm == 0) {
        return NavResult<std::shared_ptr<const GridMap>>::Failure(
            NavError::kInvalidDimensions,
            "zero identity/dimension/cell size");
    }
    if (cell_stride != kBMapCellStride || reserved0 != 0) {
        return NavResult<std::shared_ptr<const GridMap>>::Failure(
            NavError::kInvalidStride,
            "cell_stride/reserved mismatch");
    }

    const std::uint64_t cell_count =
        static_cast<std::uint64_t>(metadata.width) * metadata.height;
    const std::uint64_t expected_payload_size =
        cell_count * static_cast<std::uint64_t>(cell_stride);
    if (cell_count > std::numeric_limits<std::size_t>::max() ||
        expected_payload_size > std::numeric_limits<std::uint32_t>::max()) {
        return NavResult<std::shared_ptr<const GridMap>>::Failure(
            NavError::kSizeOverflow,
            "dimension multiplication overflow");
    }
    if (payload_size != expected_payload_size) {
        return NavResult<std::shared_ptr<const GridMap>>::Failure(
            NavError::kPayloadSizeMismatch,
            SizeDetail(expected_payload_size, payload_size));
    }

    const std::uint64_t expected_file_size = header_size + expected_payload_size;
    if (file_size < expected_file_size) {
        return NavResult<std::shared_ptr<const GridMap>>::Failure(
            NavError::kTruncated,
            SizeDetail(expected_file_size, file_size));
    }
    if (file_size > expected_file_size) {
        return NavResult<std::shared_ptr<const GridMap>>::Failure(
            NavError::kTrailingBytes,
            SizeDetail(expected_file_size, file_size));
    }

    std::array<std::uint8_t, kBMapHeaderSize> header{};
    std::copy_n(file.data(), header.size(), header.data());
    WriteU32Le(header.data() + kHeaderCrcOffset, 0);
    if (Crc32(header.data(), header.size()) != expected_header_crc) {
        return NavResult<std::shared_ptr<const GridMap>>::Failure(
            NavError::kHeaderCrcMismatch,
            "header crc mismatch");
    }

    const std::uint8_t* payload = file.data() + header_size;
    if (Crc32(payload, payload_size) != expected_payload_crc) {
        return NavResult<std::shared_ptr<const GridMap>>::Failure(
            NavError::kPayloadCrcMismatch,
            "payload crc mismatch");
    }

    std::vector<NavCell> cells;
    cells.resize(static_cast<std::size_t>(cell_count));
    for (std::size_t index = 0; index < cells.size(); ++index) {
        const std::uint8_t* source = payload + index * cell_stride;
        cells[index].height_mm = ReadI32Le(source);
        cells[index].flags = ReadU16Le(source + 4);
        cells[index].area_type = source[6];
        cells[index].clearance_cells = source[7];
    }

    try {
        std::shared_ptr<const GridMap> map =
            std::make_shared<const GridMap>(metadata, std::move(cells));
        return NavResult<std::shared_ptr<const GridMap>>::Success(std::move(map));
    } catch (const std::exception& exception) {
        return NavResult<std::shared_ptr<const GridMap>>::Failure(
            NavError::kInvalidDimensions,
            exception.what());
    }
}

}  // namespace battle_nav