#pragma once

// xxhash https://github.com/Cyan4973/xxHash
// implementation from https://www.shadertoy.com/view/Xt3cDn
uint xxhash32(const uint p)
{
    const uint PRIME32_2 = 2246822519U, PRIME32_3 = 3266489917U;
    const uint PRIME32_4 = 668265263U, PRIME32_5 = 374761393U;
    uint h32 = p + PRIME32_5;
    h32 = PRIME32_4 * ((h32 << 17) | (h32 >> (32 - 17)));
    h32 = PRIME32_2 * (h32 ^ (h32 >> 15));
    h32 = PRIME32_3 * (h32 ^ (h32 >> 13));
    return h32 ^ (h32 >> 16);
}

// PCG (https://www.pcg-random.org/)
uint pcg(const uint v)
{
    uint state = v * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

struct HashKey
{
    uint key;
    uint checksum;

    __init(const uint value)
    {
        key      = value;
        checksum = value;
    }
};

HashKey operator+(const HashKey lhs, const HashKey rhs)
{
    HashKey r;
    r.key      = pcg(lhs.key + pcg(rhs.key));
    r.checksum = xxhash32(lhs.checksum + xxhash32(rhs.checksum));
    return r;
}

void operator+=(inout HashKey lhs, const HashKey rhs)
{
    lhs.key      = pcg(lhs.key + pcg(rhs.key));
    lhs.checksum = xxhash32(lhs.checksum + xxhash32(rhs.checksum));
}

// Maps a HashKey item to a unique index.
struct HashSet
{
    static const uint kInvalidIndex = 0xFFFFFFFFu;
    static const uint kLinearProbeLength = 32;

    RWStructuredBuffer<uint> checksums;
    uint size;

    uint insert(const HashKey key, out bool first)
    {
        first = false;
        const uint checksum = min(key.checksum, 0xFFFFFFFFu - 1);
        uint cell = key.key % size;
        for (uint i = 0; i < kLinearProbeLength; i++)
        {
            uint current;
            InterlockedCompareExchange(checksums[cell], kInvalidIndex, checksum, current);
            if (current == checksum || current == kInvalidIndex)
            {
                first = (current == kInvalidIndex);
                return cell;
            }
            cell = (cell + 1) % size;
        }
        return kInvalidIndex;
    }

    uint insert(const HashKey key)
    {
        bool ignored;
        return insert(key, ignored);
    }

    uint find(const HashKey key)
    {
        const uint checksum = min(key.checksum, 0xFFFFFFFFu - 1);
        uint cell = key.key % size;
        for (uint i = 0; i < kLinearProbeLength; i++)
        {
            const uint current = checksums[cell];
            if (current == kInvalidIndex)
            {
                return kInvalidIndex;
            }
            if (current == checksum)
            {
                return cell;
            }
            cell = (cell + 1) % size;
        }
        return kInvalidIndex;
    }
};

struct MultiMap<T>
{
    RWStructuredBuffer<T>     data;
    RWStructuredBuffer<T>     sortedData;
    RWStructuredBuffer<uint2> dataIndices;
    RWStructuredBuffer<uint>  cellCounters;
    RWStructuredBuffer<uint>  cellOffsets;
    RWStructuredBuffer<uint>  counters;
    uint maxSize;

    // Get the current number of elements
    uint getSize() { return counters[0]; }

    // get the index range of elements in a cell
    uint2 getRange(const uint cell)
    {
        const uint offset = cellOffsets[cell];
        return uint2(offset, offset + cellCounters[cell]);
    }

    // get an element at an index. use getRange() to get an index range for a cell.
    T get(const uint i)
    {
        return sortedData[i];
    }

    uint insert(const uint cell, const T value)
    {
        uint i;
        InterlockedAdd(counters[0], 1, i);
        if (i >= maxSize)
        {
            return HashSet::kInvalidIndex;
        }

        uint indexInCell;
        InterlockedAdd(cellCounters[cell], 1, indexInCell);

        data[i] = value;
        dataIndices[i] = uint2(cell, indexInCell);

        return i;
    }
};
