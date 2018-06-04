/*
 * MVKDeviceMemory.mm
 *
 * Copyright (c) 2014-2018 The Brenwill Workshop Ltd. (http://www.brenwill.com)
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 * 
 *     http://www.apache.org/licenses/LICENSE-2.0
 * 
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "MVKDeviceMemory.h"
#include "MVKBuffer.h"
#include "MVKImage.h"
#include "mvk_datatypes.h"
#include "MVKFoundation.h"
#include <cstdlib>
#include <stdlib.h>

using namespace std;

#pragma mark MVKDeviceMemory

VkResult MVKDeviceMemory::map(VkDeviceSize offset, VkDeviceSize size, VkMemoryMapFlags flags, void** ppData) {

	if ( !isMemoryHostAccessible() ) {
		return mvkNotifyErrorWithText(VK_ERROR_MEMORY_MAP_FAILED, "Private GPU-only memory cannot be mapped to host memory.");
	}

	if (_isMapped) {
		return mvkNotifyErrorWithText(VK_ERROR_MEMORY_MAP_FAILED, "Memory is already mapped. Call vkUnmapMemory() first.");
	}

	if ( !ensureHostMemory() ) {
		return mvkNotifyErrorWithText(VK_ERROR_OUT_OF_HOST_MEMORY, "Could not allocate %llu bytes of host-accessible device memory.", _allocationSize);
	}

	_mapOffset = offset;
	_mapSize = adjustMemorySize(size, offset);
	_isMapped = true;

	*ppData = (void*)((uintptr_t)_pMemory + offset);

	// Coherent memory does not require flushing by app, so we must flush now, to handle any texture updates.
	pullFromDevice(offset, size, isMemoryHostCoherent());

	return VK_SUCCESS;
}

void MVKDeviceMemory::unmap() {

	if ( !_isMapped ) {
		mvkNotifyErrorWithText(VK_ERROR_MEMORY_MAP_FAILED, "Memory is not mapped. Call vkMapMemory() first.");
		return;
	}

	// Coherent memory does not require flushing by app, so we must flush now.
	flushToDevice(_mapOffset, _mapSize, isMemoryHostCoherent());

	_mapOffset = 0;
	_mapSize = 0;
	_isMapped = false;
}

VkResult MVKDeviceMemory::flushToDevice(VkDeviceSize offset, VkDeviceSize size, bool evenIfCoherent) {
	// Coherent memory is flushed on unmap(), so it is only flushed if forced
	VkDeviceSize memSize = adjustMemorySize(size, offset);
	if (memSize > 0 && isMemoryHostAccessible() && (evenIfCoherent || !isMemoryHostCoherent()) ) {

#if MVK_MACOS
		if (_mtlBuffer && _mtlStorageMode == MTLStorageModeManaged) {
			[_mtlBuffer didModifyRange: NSMakeRange(offset, memSize)];
		}
#endif

		lock_guard<mutex> lock(_rezLock);
        for (auto& img : _images) { img->flushToDevice(offset, memSize); }
	}
	return VK_SUCCESS;
}

VkResult MVKDeviceMemory::pullFromDevice(VkDeviceSize offset, VkDeviceSize size, bool evenIfCoherent) {
	// Coherent memory is flushed on unmap(), so it is only flushed if forced
    VkDeviceSize memSize = adjustMemorySize(size, offset);
	if (memSize > 0 && isMemoryHostAccessible() && (evenIfCoherent || !isMemoryHostCoherent()) ) {
		lock_guard<mutex> lock(_rezLock);
        for (auto& img : _images) { img->pullFromDevice(offset, memSize); }
	}
	return VK_SUCCESS;
}

// If the size parameter is the special constant VK_WHOLE_SIZE, returns the size of memory
// between offset and the end of the buffer, otherwise simply returns size.
VkDeviceSize MVKDeviceMemory::adjustMemorySize(VkDeviceSize size, VkDeviceSize offset) {
	return (size == VK_WHOLE_SIZE) ? (_allocationSize - offset) : size;
}

VkResult MVKDeviceMemory::addBuffer(MVKBuffer* mvkBuff) {
	lock_guard<mutex> lock(_rezLock);

	if (!ensureMTLBuffer() ) {
		return mvkNotifyErrorWithText(VK_ERROR_OUT_OF_DEVICE_MEMORY, "Could not bind a VkBuffer to a VkDeviceMemory of size %llu bytes. The maximum memory-aligned size of a VkDeviceMemory that supports a VkBuffer is %llu bytes.", _allocationSize, _device->_pMetalFeatures->maxMTLBufferSize);
	}

	_buffers.push_back(mvkBuff);

	return VK_SUCCESS;
}

void MVKDeviceMemory::removeBuffer(MVKBuffer* mvkBuff) {
	lock_guard<mutex> lock(_rezLock);
	mvkRemoveAllOccurances(_buffers, mvkBuff);
}

VkResult MVKDeviceMemory::addImage(MVKImage* mvkImg) {
	lock_guard<mutex> lock(_rezLock);

	_images.push_back(mvkImg);

	return VK_SUCCESS;
}

void MVKDeviceMemory::removeImage(MVKImage* mvkImg) {
	lock_guard<mutex> lock(_rezLock);
	mvkRemoveAllOccurances(_images, mvkImg);
}

// Ensures that this instance is backed by a MTLBuffer object,
// creating the MTLBuffer if needed, and returns whether it was successful.
bool MVKDeviceMemory::ensureMTLBuffer() {

	if (_mtlBuffer) { return true; }

	NSUInteger memLen = mvkAlignByteOffset(_allocationSize, _device->_pMetalFeatures->mtlBufferAlignment);

	if (memLen > _device->_pMetalFeatures->maxMTLBufferSize) { return false; }

	// If host memory was already allocated, it is copied into the new MTLBuffer, and then released.
	if (_pHostMemory) {
		_mtlBuffer = [getMTLDevice() newBufferWithBytes: _pHostMemory length: memLen options: _mtlResourceOptions];     // retained
		freeHostMemory();
	} else {
		_mtlBuffer = [getMTLDevice() newBufferWithLength: memLen options: _mtlResourceOptions];     // retained
	}
	_pMemory = _mtlBuffer.contents;

	return true;
}

// Ensures that host-accessible memory is available, allocating it if necessary.
bool MVKDeviceMemory::ensureHostMemory() {

	if (_pMemory) { return true; }

	if ( !_pHostMemory) {
		size_t memAlign = _device->_pMetalFeatures->mtlBufferAlignment;
		NSUInteger memLen = mvkAlignByteOffset(_allocationSize, memAlign);
		int err = posix_memalign(&_pHostMemory, memAlign, memLen);
		if (err) { return false; }
	}

	_pMemory = _pHostMemory;

	return true;
}

void MVKDeviceMemory::freeHostMemory() {
	free(_pHostMemory);
	_pHostMemory = nullptr;
}

MVKDeviceMemory::MVKDeviceMemory(MVKDevice* device,
								 const VkMemoryAllocateInfo* pAllocateInfo,
								 const VkAllocationCallbacks* pAllocator) : MVKBaseDeviceObject(device) {
	// Set Metal memory parameters
	VkMemoryPropertyFlags vkMemProps = _device->_pMemoryProperties->memoryTypes[pAllocateInfo->memoryTypeIndex].propertyFlags;
	_mtlResourceOptions = mvkMTLResourceOptionsFromVkMemoryPropertyFlags(vkMemProps);
	_mtlStorageMode = mvkMTLStorageModeFromVkMemoryPropertyFlags(vkMemProps);
	_mtlCPUCacheMode = mvkMTLCPUCacheModeFromVkMemoryPropertyFlags(vkMemProps);

	_allocationSize = pAllocateInfo->allocationSize;

	// If memory needs to be coherent it must reside in an MTLBuffer, since an open-ended map() must work.
	if (isMemoryHostCoherent() && !ensureMTLBuffer() ) {
		setConfigurationResult(mvkNotifyErrorWithText(VK_ERROR_OUT_OF_DEVICE_MEMORY, "Could not allocate a host-coherent VkDeviceMemory of size %llu bytes. The maximum memory-aligned size of a host-coherent VkDeviceMemory is %llu bytes.", _allocationSize, _device->_pMetalFeatures->maxMTLBufferSize));
	}
}

MVKDeviceMemory::~MVKDeviceMemory() {
    // Unbind any resources that are using me. Iterate a copy of the collection,
    // to allow the resource to callback to remove itself from the collection.
    auto buffCopies = _buffers;
    for (auto& buf : buffCopies) { buf->bindDeviceMemory(nullptr, 0); }
	auto imgCopies = _images;
	for (auto& img : imgCopies) { img->bindDeviceMemory(nullptr, 0); }

	[_mtlBuffer release];
	_mtlBuffer = nil;

	freeHostMemory();
}
