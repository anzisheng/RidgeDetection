/**
 * @file test_dynamic_vector.cu
 * @author     Adam Rogowiec
 *
 * This file is an integral part of the master thesis entitled:
 * "Elaboration and implementation in CUDA technology parallel version of
 * estimation of multidimensional random variable density function ridge
 * detection algorithm."
 * , which is conducted under the supervision of prof. dr hab. inż. Marek
 * Nałęcz.
 *
 * Institute of Control and Computation Engineering Faculty of Electronics and
 * Information Technology Warsaw University of Technology 2016
 */

#define CUB_STDERR
#define BLOCK_TILE_LOAD_V4 1


#include "rd/utils/cmd_line_parser.hpp"
#include "rd/utils/utilities.hpp"
#include "rd/utils/memory.h" 
#include "rd/utils/rd_params.hpp"
#include "rd/utils/name_traits.hpp"
#include "rd/utils/graph_drawer.hpp"
#include "rd/gpu/util/dev_samples_set.cuh"
 
#include "rd/gpu/agent/agent_memcpy.cuh"
#include "rd/gpu/block/block_dynamic_vector.cuh"

#include "cub/test_util.h"
#include "cub/util_ptx.cuh"

#include <helper_cuda.h>
#include <cuda_runtime.h>
#include <vector_types.h>
#include <cuda_profiler_api.h>

#include <iostream>
#include <string>
#include <vector>
#include <sstream>
#include <fstream>
#include <iomanip>
#include <typeinfo>
#include <stdexcept>
#include <utility>
#include <algorithm>

//------------------------------------------------------------
//  GLOBAL CONSTANTS / VARIABLES
//------------------------------------------------------------

static const std::string LOG_FILE_NAME_SUFFIX = "_dyn_vec_timings.txt";
static constexpr int ZERO = 0;

std::ofstream * g_logFile       = nullptr;
bool            g_drawAllGraphs = false;
bool            g_drawGraphs    = false;
bool 			g_deviceHeapLimitSet = false;
std::string     g_devName;

std::vector<std::vector<float>> g_bestPerf;
const float                     g_graphColStep = 0.3f;
const int                       g_graphNCol = 8;        // group columns count 
const int                       g_graphNGroups = 6;     // number of dimensions to plot
    
#if defined(RD_DEBUG) || defined(RD_PROFILE)
const int g_iterations = 1;
#else
const int g_iterations = 100;
#endif

__device__ int g_outputBuffOffset = 0;

//------------------------------------------------------------
//  TILE PROCESSING CLASS
//------------------------------------------------------------

template <
    typename                    BlockTileLoadPolicyT,
    typename                    BlockTileStorePolicyT,
    int                         DIM,
    rd::DataMemoryLayout        MEM_LAYOUT,
    rd::DataMemoryLayout        PRIVATE_MEM_LAYOUT,
    rd::gpu::BlockTileIOBackend IO_BACKEND,
    typename                    OffsetT,
    typename                    SampleT>
class AgentTileProcessing
{

    //---------------------------------------------------------------------
    // Types and constants
    //---------------------------------------------------------------------

    /// Constants
    enum
    {
        BLOCK_THREADS           = BlockTileLoadPolicyT::BLOCK_THREADS,
        POINTS_PER_THREAD       = BlockTileLoadPolicyT::POINTS_PER_THREAD,
        TILE_POINTS             = POINTS_PER_THREAD * BLOCK_THREADS,

        SAMPLES_PER_THREAD      = POINTS_PER_THREAD * DIM,
        TILE_SAMPLES            = SAMPLES_PER_THREAD * BLOCK_THREADS,
    };

    typedef rd::gpu::BlockTileLoad<
        BlockTileLoadPolicyT,
        DIM,
        MEM_LAYOUT, 
        IO_BACKEND,
        SampleT, 
        OffsetT> BlockTileLoadT;

    typedef rd::gpu::BlockTileStore<
        BlockTileStorePolicyT,
        DIM,
        MEM_LAYOUT,
        IO_BACKEND,
        SampleT,
        OffsetT> BlockTileStoreT;

    typedef rd::gpu::BlockDynamicVector<
        BLOCK_THREADS, 
        SAMPLES_PER_THREAD, 
        SampleT> VectorT;
    //---------------------------------------------------------------------
    // Per-thread fields
    //---------------------------------------------------------------------

    /// Native pointer for input samples 
    SampleT const *     d_in;
    VectorT             outputVector;

     //---------------------------------------------------------------------
    // Tile processing
    //---------------------------------------------------------------------

    // Consume a tile of data samples. Specialized for full tile
    __device__ __forceinline__ void consumeTile(
        OffsetT                     globalTileOffset,
        OffsetT                     blockTileOffset,
        OffsetT                     stride,
        cub::Int2Type<rd::ROW_MAJOR>    privateMemLayout)
    {
        typename BlockTileLoadT::ThreadPrivatePoints<rd::ROW_MAJOR> samples;

        #ifdef RD_DEBUG
        if (threadIdx.x == 0)
        {
            _CubLog("__AgentTileProcessing__(full tile): load range: [%p, %p]\n", d_in + globalTileOffset * DIM, d_in + globalTileOffset * DIM + TILE_SAMPLES);
        }
        #endif
        
        BlockTileLoadT::loadTile2Row(d_in, samples.data, globalTileOffset, stride);
        

        outputVector.resize(outputVector.size() + TILE_SAMPLES);

        #ifdef RD_DEBUG
        if (threadIdx.x == 0)
        {
            _CubLog("__AgentTileProcessing__(full tile): store range: [%p, %p]\n", outputVector.begin() + globalTileOffset * DIM, outputVector.begin() + globalTileOffset * DIM + TILE_SAMPLES);
        }
        #endif

        BlockTileStoreT::storeTile2Row(outputVector.begin(), samples.data, blockTileOffset, stride);

        #ifdef RD_DEBUG
        if (threadIdx.x == 0)
        {
            _CubLog("__AgentTileProcessing__(full tile): tile: %d stored!\n", globalTileOffset);
        }
        #endif

        outputVector.incrementItemsCnt(TILE_SAMPLES, true);
    }

    // Consume a tile of data samples. Specialized for full tile
    // __device__ __forceinline__ void consumeTile(
    //     OffsetT                     blockOffset,
    //     OffsetT                     stride,
    //     cub::Int2Type<rd::COL_MAJOR>    privateMemLayout)
    // {
    //     typename BlockTileLoadT::ThreadPrivatePoints<rd::COL_MAJOR> samples;
    //     BlockTileLoadT::loadTile2Col(d_in + blockOffset, samples.data, stride);
    //     BlockTileStoreT::storeTile2Col(d_out + blockOffset, samples.data, stride);
        
    // }

    // Consume a tile of data samples. Specialized for partial tile
    __device__ __forceinline__ void consumeTile(
        OffsetT                     globalTileOffset,
        OffsetT                     blockTileOffset,
        int                         validPoints,
        OffsetT                     stride,
        cub::Int2Type<rd::ROW_MAJOR>    privateMemLayout)
    {
        typename BlockTileLoadT::ThreadPrivatePoints<rd::ROW_MAJOR> samples;

        #ifdef RD_DEBUG
        if (threadIdx.x == 0)
        {
            _CubLog("__AgentTileProcessing__(partial tile): load range: [%p, %p]\n", d_in + globalTileOffset * DIM, d_in + globalTileOffset * DIM + validPoints * DIM);
        }
        #endif

        BlockTileLoadT::loadTile2Row(d_in, samples.data, globalTileOffset, validPoints, stride);

        #ifdef RD_DEBUG
        if (threadIdx.x == 0)
        {
            _CubLog("__AgentTileProcessing__(partial tile): store range: [%p, %p]\n", outputVector.begin() + globalTileOffset * DIM, outputVector.begin() + globalTileOffset * DIM + validPoints * DIM);
        }
        #endif

        outputVector.resize(outputVector.size() + validPoints * DIM);

        BlockTileStoreT::storeTile2Row(outputVector.begin(), samples.data, blockTileOffset, validPoints, stride);

        #ifdef RD_DEBUG
        if (threadIdx.x == 0)
        {
            _CubLog("__AgentTileProcessing__(partial tile): tile: %d stored!\n", globalTileOffset);
        }
        #endif

        outputVector.incrementItemsCnt(validPoints * DIM, true);
    }


    // Consume a tile of data samples. Specialized for partial tile
    // __device__ __forceinline__ void consumeTile(
    //     OffsetT                     blockOffset,
    //     int                         validPoints,
    //     OffsetT                     stride,
    //     cub::Int2Type<rd::COL_MAJOR>    privateMemLayout)
    // {
    //     typename BlockTileLoadT::ThreadPrivatePoints<rd::COL_MAJOR> samples;
    //     BlockTileLoadT::loadTile2Col(d_in + blockOffset, validPoints, samples.data, stride);
    //     BlockTileStoreT::storeTile2Col(d_out + blockOffset, validPoints, samples.data, stride);
    // }


    __device__ __forceinline__ void consumeTiles(
        OffsetT numPoints,
        OffsetT stride)
    {
        OffsetT numTiles = (numPoints + TILE_POINTS - 1) / TILE_POINTS;
        for (int t = blockIdx.x, k = 0; t < numTiles; t += gridDim.x, ++k)
        {
            OffsetT globalTileOffset = t * TILE_POINTS;
            OffsetT blockTileOffset = k * TILE_POINTS;

            #ifdef RD_DEBUG
            if (threadIdx.x == 0)
            {
            	_CubLog("::::::t: %d, k: %d, globalTilePointOffset: %d, blockTilePointOffset %d\n", t, k, globalTileOffset, blockTileOffset);
            }
            #endif

            if (globalTileOffset + TILE_POINTS > numPoints)
            {
                // Consume partial tile
                consumeTile(globalTileOffset, blockTileOffset, numPoints - globalTileOffset, stride, cub::Int2Type<MEM_LAYOUT>());
            }
            else
            {
                // Consume full tile
                consumeTile(globalTileOffset, blockTileOffset, stride, cub::Int2Type<MEM_LAYOUT>());
            }
        }
    }  

public:
    //---------------------------------------------------------------------
    // Interface
    //---------------------------------------------------------------------


    /**
     * Constructor
     */
    __device__ __forceinline__ AgentTileProcessing(
        SampleT const *         d_InputSamples)
    :
        d_in(d_InputSamples)
    {
        // #ifdef RD_DEBUG
            // unsigned int vs = outputVector.size();
            // if (threadIdx.x == 0)
            // {
                // printf("Memset!\n");
                // SampleT * ptr = outputVector.begin();
                // CubDebug(cudaMemsetAsync(ptr, 0, vs * sizeof(SampleT), 0));
                // CubDebug(cudaPeekAtLastError());
                // CubDebug(cudaDeviceSynchronize());
            // }
            // __syncthreads();
        // #endif
    }


    /**
     * Destructor
     */
    __device__ __forceinline__ ~AgentTileProcessing()
    {
        // release allocated device heap memory
        if (threadIdx.x == 0)
        {
            #ifdef RD_DEBUG
                _CubLog("Releasing dynamic vector, size: %u\n", outputVector.size());
            #endif
            outputVector.clear();
        }
    }

    /**
     * Consume data
     */
    __device__ __forceinline__ OffsetT consumeRange(
        OffsetT             startOffset,
        OffsetT             numPoints,
        OffsetT             stride)      /// Number of samples between point's consecutive coordinates
    {
        d_in += startOffset;
        consumeTiles(numPoints, stride);

        return outputVector.size();
        // #ifdef RD_DEBUG
        //     outputVector.print();
        // #endif
    }

    __device__ __forceinline__ SampleT * data() 
    {
        return outputVector.begin();
    }
};

/******************************************************************************
 * Load Store kernel entry point
 *****************************************************************************/

template<
    typename                    BlockTileLoadPolicyT,
    typename                    BlockTileStorePolicyT,
    int                         DIM,
    rd::DataMemoryLayout        MEM_LAYOUT,
    rd::DataMemoryLayout        PRIVATE_MEM_LAYOUT,
    rd::gpu::BlockTileIOBackend IO_BACKEND,
    typename                    SampleT,
    typename                    OffsetT>
__launch_bounds__ (int(BlockTileLoadPolicyT::BLOCK_THREADS))
__global__ void deviceTileProcessingKernel(
    SampleT const *         d_in,
    SampleT *               d_out,
    int                     numPoints,
    OffsetT *               d_blockItemsCnt,
    OffsetT                 offset,
    OffsetT                 stride,
    bool                    correctnessCheck)
{
    typedef AgentTileProcessing<
        BlockTileLoadPolicyT,
        BlockTileStorePolicyT,
        DIM,
        MEM_LAYOUT,
        PRIVATE_MEM_LAYOUT,
        IO_BACKEND,
        OffsetT,
        SampleT> AgentTileProcessingT;

    AgentTileProcessingT tileProcessing(d_in);
    d_blockItemsCnt[blockIdx.x] = tileProcessing.consumeRange(offset, numPoints, stride);

    if (correctnessCheck)
    {
        #ifdef RD_DEBUG
            if (threadIdx.x == 0)
            {
                printf("copying back data....\n");
            }
        #endif

        typedef rd::gpu::AgentMemcpy<
            BlockTileLoadPolicyT,
            BlockTileStorePolicyT,
            DIM,
            MEM_LAYOUT,
            PRIVATE_MEM_LAYOUT,
            IO_BACKEND,
            OffsetT,
            SampleT> MemcpyEngineT;

        OffsetT storedValuesCnt = *(d_blockItemsCnt + blockIdx.x);
        if (storedValuesCnt == 0)
        {
            return;
        }

        OffsetT outputBuffOffset;
        __shared__ OffsetT outputOffset;
        if (threadIdx.x == 0)
        {
            outputOffset = atomicAdd(&g_outputBuffOffset, storedValuesCnt);
        }
        __syncthreads();
        outputBuffOffset = outputOffset;
        #ifdef RD_DEBUG
            if (threadIdx.x == 0)
            {
                _CubLog("storedValuesCnt: %d outputBuffOffset: %d, memcpy in: %p, memcpy out(start): %p, memcpy out(end): %p\n",
                     storedValuesCnt, outputBuffOffset, tileProcessing.data(), d_out + outputBuffOffset, d_out + outputBuffOffset + storedValuesCnt);
            }
        #endif

        MemcpyEngineT(tileProcessing.data(), d_out + outputBuffOffset).copyRange(0, storedValuesCnt / DIM, stride, true);
        __syncthreads();
        #ifdef RD_DEBUG
            if (threadIdx.x == 0)
            {
                printf("[(block: %d)--------- END copying back data! ------------\n", blockIdx.x);
            }
        #endif
    }
}

struct KernelConfig
{
    int blockThreads;
    int itemsPerThread;
};

//---------------------------------------------------------------------
// Kernel Invocation
//---------------------------------------------------------------------

template <
    typename    SampleT,
    typename    OffsetT, 
    typename    LoadStoreKernelPtrT>
static cudaError_t invoke(
    SampleT const *         d_in,
    SampleT *               d_out,
    int                     numPoints,
    int &                   numBlocksLaunched,
    int *                   d_blockItemsCnt,
    OffsetT                 offset,
    OffsetT                 stride,
    cudaStream_t            stream,
    bool                    correctnessCheck,
    bool                    debugSynchronous,
    LoadStoreKernelPtrT     kernelPtr,
    KernelConfig            kernelConfig)
{
    cudaError error = cudaSuccess;
    do
    {           
        // Get device ordinal
        int deviceOrdinal;
        if (CubDebug(error = cudaGetDevice(&deviceOrdinal))) break;

        // Get SM count
        int smCount;
        if (CubDebug(error = cudaDeviceGetAttribute(&smCount, cudaDevAttrMultiProcessorCount, deviceOrdinal))) break;

        // get SM occupancy
        int smOccupancy;
        if (CubDebug(error = cub::MaxSmOccupancy(
            smOccupancy,
            kernelPtr,
            kernelConfig.blockThreads)
        )) break;

        dim3 boundsGridSize(1);
        boundsGridSize.x = smCount * smOccupancy * 4;
        numBlocksLaunched = boundsGridSize.x;

        // only asking for numBlocksLaunched
        if (d_blockItemsCnt == nullptr)
        {
            break;
        }

        if (debugSynchronous)
        {
            printf("Invoking deviceLoadStoreKernel<<<%d, %d, 0, %lld>>> numPoints: %d, itemsPerThread: %d, offset %d, correctnessCheck %d\n",
                boundsGridSize.x, kernelConfig.blockThreads, (long long)stream, numPoints, kernelConfig.itemsPerThread, offset, (int)correctnessCheck);
        }

        kernelPtr<<<boundsGridSize.x, kernelConfig.blockThreads, 0, stream>>>(
            d_in,
            d_out,
            numPoints,
            d_blockItemsCnt,
            offset,
            stride,
            correctnessCheck);

        // Check for failure to launch
        if (CubDebug(error = cudaPeekAtLastError())) break;
        // Sync the stream if specified to flush runtime errors
        if (debugSynchronous && (CubDebug(error = cub::SyncStream(stream)))) break;
        // reset g_outputBuffOffset
        if (debugSynchronous && (CubDebug(error = cudaMemcpyToSymbol(g_outputBuffOffset, &ZERO, sizeof(int)))));

        #ifdef RD_DEBUG
            printf(">>>> End deviceLoadStoreKernel... \n");
        #endif
    } while (0);

    return error;
}

//------------------------------------------------------------
//  KERNEL DISPATCH
//------------------------------------------------------------

template <
    int                         BLOCK_THREADS,
    int                         POINTS_PER_THREAD,
    int                         DIM,
    cub::CacheLoadModifier      LOAD_MODIFIER,
    cub::CacheStoreModifier     STORE_MODIFIER,
    rd::DataMemoryLayout        MEM_LAYOUT,
    rd::DataMemoryLayout        PRIVATE_MEM_LAYOUT,
    rd::gpu::BlockTileIOBackend IO_BACKEND,
    typename                    OffsetT,                     
    typename                    T>
void dispatchTileProcessingKernel(
    T const *           d_in,
    T *                 d_out,
    int                 numPoints,
    int &               numBlocksLaunched,
    int *               d_blockItemsCnt,
    OffsetT             offset,
    OffsetT             stride,
    int                 iterations,
    bool                correctnessCheck = false,       ///< whether or not copy back data to device vector for correctnes check
    bool                debugSynchronous = false)
{
    typedef rd::gpu::BlockTileLoadPolicy<
        BLOCK_THREADS,
        POINTS_PER_THREAD,
        LOAD_MODIFIER> BlockTileLoadPolicyT;

    typedef rd::gpu::BlockTileStorePolicy<
        BLOCK_THREADS,
        POINTS_PER_THREAD,
        STORE_MODIFIER> BlockTileStorePolicyT;

    KernelConfig tileProcessingConfig;
    tileProcessingConfig.blockThreads = BLOCK_THREADS;
    tileProcessingConfig.itemsPerThread = POINTS_PER_THREAD;

    for (int i = 0; i < iterations; ++i)
    {
        CubDebugExit(invoke(
            d_in,
            d_out,
            numPoints,
            numBlocksLaunched,
            d_blockItemsCnt,
            offset,
            stride,
            0,
            correctnessCheck,
            debugSynchronous,
            deviceTileProcessingKernel<BlockTileLoadPolicyT, BlockTileStorePolicyT, DIM, MEM_LAYOUT, PRIVATE_MEM_LAYOUT, IO_BACKEND, T, OffsetT>,
            tileProcessingConfig));
    }
}

//------------------------------------------------------------
//  Benchmark helper structures
//------------------------------------------------------------

struct KernelParametersConf
{
    int                         BLOCK_THREADS;
    int                         POINTS_PER_THREAD;
    int                         DIM;
    cub::CacheLoadModifier      LOAD_MODIFIER;
    cub::CacheStoreModifier     STORE_MODIFIER;
    rd::DataMemoryLayout        MEM_LAYOUT;
    rd::DataMemoryLayout        PRIVATE_MEM_LAYOUT;
    rd::gpu::BlockTileIOBackend IO_BACKEND;
    float                       avgMillis;
    float                       gigaBandwidth;

    KernelParametersConf()
    :
        LOAD_MODIFIER(cub::LOAD_DEFAULT),
        STORE_MODIFIER(cub::STORE_DEFAULT),
        MEM_LAYOUT(rd::ROW_MAJOR),
        PRIVATE_MEM_LAYOUT(rd::ROW_MAJOR),
        IO_BACKEND(rd::gpu::IO_BACKEND_CUB)
    {}

    KernelParametersConf(
        int                         _DIM,
        cub::CacheLoadModifier      _LOAD_MODIFIER,
        cub::CacheStoreModifier     _STORE_MODIFIER,
        rd::DataMemoryLayout        _MEM_LAYOUT,
        rd::DataMemoryLayout        _PRIVATE_MEM_LAYOUT,
        rd::gpu::BlockTileIOBackend _IO_BACKEND)
    :
        DIM(_DIM),
        LOAD_MODIFIER(_LOAD_MODIFIER),
        STORE_MODIFIER(_STORE_MODIFIER),
        MEM_LAYOUT(_MEM_LAYOUT),
        PRIVATE_MEM_LAYOUT(_PRIVATE_MEM_LAYOUT),
        IO_BACKEND(_IO_BACKEND)
    {}

};

typedef std::pair<float, float> KernelPerfT;

//------------------------------------------------------------
//  TEST CONFIGURATION AND RUN
//------------------------------------------------------------

template <
    int                         BLOCK_THREADS,
    int                         POINTS_PER_THREAD,
    int                         DIM,
    cub::CacheLoadModifier      LOAD_MODIFIER,
    cub::CacheStoreModifier     STORE_MODIFIER,
    rd::DataMemoryLayout        MEM_LAYOUT,
    rd::DataMemoryLayout        PRIVATE_MEM_LAYOUT,
    rd::gpu::BlockTileIOBackend IO_BACKEND,
    typename                    OffsetT,                     
    typename                    T>
KernelPerfT runTileProcessing(
    rd::RDParams<T> const &         rdp,
    T const *                       d_in,
    T *                             d_out,
    T *                             h_in,
    OffsetT                         offset,
    OffsetT                         stride)
{
    std::cout << rd::HLINE << std::endl;
    std::cout << "runTestLoadStore:" << std::endl;
    std::cout << "blockThreads: " << BLOCK_THREADS 
              << ", pointsPerThread: " << POINTS_PER_THREAD
              << ", load modifier: " << rd::LoadModifierNameTraits<LOAD_MODIFIER>::name
              << ", store modifier: " << rd::StoreModifierNameTraits<STORE_MODIFIER>::name
              << ", mem layout: " << rd::DataMemoryLayoutNameTraits<MEM_LAYOUT>::name
              << ", priv mem layout: " << rd::DataMemoryLayoutNameTraits<PRIVATE_MEM_LAYOUT>::name
              << ", io backend: " << rd::BlockTileIONameTraits<IO_BACKEND>::name
              << ", numPoints: " << rdp.np << "\n";

    #ifdef RD_DEBUG
    std::cout.flush();
    #endif

    T * h_out;   
    int * h_blockItemsCnt;
    int numBlocksLaunched = 0;
    int * d_blockItemsCnt = nullptr;

    // Query for number of blocks to launch
    dispatchTileProcessingKernel<BLOCK_THREADS, POINTS_PER_THREAD, DIM, LOAD_MODIFIER, STORE_MODIFIER, MEM_LAYOUT, PRIVATE_MEM_LAYOUT, IO_BACKEND>(
        d_in, d_out, rdp.np, numBlocksLaunched, d_blockItemsCnt, offset, stride, 1, true, true);
    
    /*
     *  Allocate output containers for correctness check
     */
    checkCudaErrors(cudaMalloc(&d_blockItemsCnt, numBlocksLaunched * sizeof(int)));
    h_blockItemsCnt = new int[numBlocksLaunched];

    // Run warm-up/correctness iteration
    dispatchTileProcessingKernel<BLOCK_THREADS, POINTS_PER_THREAD, DIM, LOAD_MODIFIER, STORE_MODIFIER, MEM_LAYOUT, PRIVATE_MEM_LAYOUT, IO_BACKEND>(
        d_in, d_out, rdp.np, numBlocksLaunched, d_blockItemsCnt, offset, stride, 1, true, true);
    checkCudaErrors(cudaGetLastError());
    checkCudaErrors(cudaDeviceSynchronize());

    #ifdef RD_DEBUG
        printf(">>>> End correctness iteration. Copying data from device... \n");
    #endif

    checkCudaErrors(cudaMemcpy(h_blockItemsCnt, d_blockItemsCnt, numBlocksLaunched * sizeof(int), cudaMemcpyDeviceToHost));
    checkCudaErrors(cudaDeviceSynchronize());

    size_t totalItemsCnt = 0;
    for (int k = 0; k < numBlocksLaunched; ++k)
    {
        totalItemsCnt += h_blockItemsCnt[k];
    }
    if (totalItemsCnt != rdp.np * DIM)
    {
        std::cout << ">>>> ERROR! incorrect totalItemsCnt: " << totalItemsCnt << std::endl;
        // clean-up
        
        delete[] h_blockItemsCnt;
        checkCudaErrors(cudaFree(d_blockItemsCnt));
        exit(0);
    }
    else
    {
        std::cout << ">>>>> totalItemsCnt: " << totalItemsCnt << "... CORRECT!\n";
    }
    #ifdef RD_DEBUG
    std::cout.flush();
    #endif

    h_out = new T[totalItemsCnt];
    checkCudaErrors(cudaMemcpy(h_out, d_out, totalItemsCnt * sizeof(T), cudaMemcpyDeviceToHost));
    checkCudaErrors(cudaDeviceSynchronize());

    #ifdef RD_DEBUG
        printf(">>>> End copying data from device. Sorting results... \n");
    #endif

    // sort both results so that we can compare them
    // std::sort(h_in, h_in + rdp.np * DIM);
    std::sort(h_out, h_out + totalItemsCnt);

    bool result = rd::checkResult(h_in, h_out, rdp.np * DIM);
    if (result)
    {
        std::cout << ">>>> CORRECT!\n";
    }
    else
    {
        std::cout << ">>>> ERROR! incorrect results" << std::endl;
        // clean-up
        
        delete[] h_out;
        delete[] h_blockItemsCnt;
        checkCudaErrors(cudaFree(d_blockItemsCnt));
        exit(0);
    }
    #ifdef RD_DEBUG
    std::cout.flush();
    #endif

    // Measure performance
    GpuTimer timer;
    float elapsedMillis;

    #ifdef RD_DEBUG
        printf(">>>> Measuring performance... \n");
    #endif

    #ifdef RD_PROFILE
    cudaProfilerStart();
    #endif
    timer.Start();

    dispatchTileProcessingKernel<BLOCK_THREADS, POINTS_PER_THREAD, DIM, LOAD_MODIFIER, STORE_MODIFIER, MEM_LAYOUT, PRIVATE_MEM_LAYOUT, IO_BACKEND>(
        d_in, d_out, rdp.np, numBlocksLaunched, d_blockItemsCnt, offset, stride, g_iterations, false, false);

    timer.Stop();
    elapsedMillis = timer.ElapsedMillis();
    checkCudaErrors(cudaDeviceSynchronize());
    #ifdef RD_PROFILE
    cudaProfilerStop();
    #endif

    float avgMillis = elapsedMillis / g_iterations;
    float gigaRate = float(rdp.np * DIM) / avgMillis / 1000.0 / 1000.0;
    float gigaBandwidth = gigaRate * 2 * sizeof(T);

    std::cout << avgMillis << " avg ms, "
              // << gigaRate << " billion samples/s, "
              // << gigaRate / DIM << " billion points/s " 
              << gigaBandwidth << " logical GB/s\n";
    #ifdef RD_DEBUG
    std::cout.flush();
    #endif

    if (rdp.verbose)
    {
        *g_logFile << POINTS_PER_THREAD << " " << BLOCK_THREADS << " " << avgMillis << " " << gigaBandwidth << "\n";
    }

    // clean-up

    delete[] h_out;
    delete[] h_blockItemsCnt;
    checkCudaErrors(cudaFree(d_blockItemsCnt));

    return std::make_pair(avgMillis, gigaBandwidth);
}


/*
 *  Specialization for testing different points per thread
 */
template <
    int                         DIM,
    cub::CacheLoadModifier      LOAD_MODIFIER,
    cub::CacheStoreModifier     STORE_MODIFIER,
    rd::DataMemoryLayout        MEM_LAYOUT,
    rd::DataMemoryLayout        PRIVATE_MEM_LAYOUT,
    rd::gpu::BlockTileIOBackend IO_BACKEND,
    typename                    OffsetT,                     
    typename                    T>
KernelParametersConf testBlockPointsPerThreadConf(
    rd::RDParams<T> const &         rdp,
    T const *                       d_in,
    T *                             d_out,
    T *                             h_in,
    OffsetT                         offset,
    OffsetT                         stride)
{
    if (rdp.verbose)
    {
        *g_logFile << "%\n testBlockPointsPerThreadConf: "
            << ", load modifier: " << rd::LoadModifierNameTraits<LOAD_MODIFIER>::name
            << ", store modifier: " << rd::StoreModifierNameTraits<STORE_MODIFIER>::name
            << ", mem layout: " << rd::DataMemoryLayoutNameTraits<MEM_LAYOUT>::name
            << ", priv mem layout: " << rd::DataMemoryLayoutNameTraits<PRIVATE_MEM_LAYOUT>::name
            << ", io backend: " << rd::BlockTileIONameTraits<IO_BACKEND>::name
            << ", numPoints: " << rdp.np << "\n";
    }

    KernelParametersConf bestKernelParams(DIM, LOAD_MODIFIER, STORE_MODIFIER, MEM_LAYOUT, PRIVATE_MEM_LAYOUT, IO_BACKEND);
    KernelPerfT bestPerf = std::make_pair(1e10f, -1.0f);


    typedef std::pair<int, std::vector<T>> graphLineDataT;
    std::vector<graphLineDataT> graphData;

    auto processResult = [&](int bs, int ppt, KernelPerfT kp)
    {
        if (kp.second > bestPerf.second)
        {
            bestPerf.first = kp.first;
            bestPerf.second = kp.second;
            bestKernelParams.avgMillis = kp.first;
            bestKernelParams.gigaBandwidth = kp.second;
            bestKernelParams.BLOCK_THREADS = bs;
            bestKernelParams.POINTS_PER_THREAD = ppt;
        }

        if (g_drawAllGraphs)
        {
            if (graphData.empty() || graphData.back().first != bs)
            {
                graphData.emplace_back(graphLineDataT(bs, std::vector<T>{float(ppt), kp.second}));
            } 
            else 
            {
                graphData.back().second.push_back(ppt);
                graphData.back().second.push_back(kp.second);
            }
        }
    };

#define runTest(bs, ppt) processResult(bs, ppt, runTileProcessing<bs, ppt, DIM, LOAD_MODIFIER, STORE_MODIFIER, MEM_LAYOUT, PRIVATE_MEM_LAYOUT, IO_BACKEND>(rdp, d_in, d_out, h_in, offset, stride));
    
    // runTest(64, 1);
    // runTest(64, 2);
    // runTest(64, 3);
    runTest(64, 4);
    // runTest(64, 5);
    // runTest(64, 6);
    // runTest(64, 7);
    // runTest(64, 8);
    // runTest(64, 9);
    // runTest(64, 10);

    // runTest(96, 1);
    // runTest(96, 2);
    // runTest(96, 3);
    // runTest(96, 4);
    // runTest(96, 5);
    // runTest(96, 6);
    // runTest(96, 7);
    // runTest(96, 8);
    // runTest(96, 9);
    // runTest(96, 10);

    // runTest(128, 1);
    // runTest(128, 2);
    // runTest(128, 3);
    // runTest(128, 4);
    // runTest(128, 5);
    // runTest(128, 6);
    // runTest(128, 7);
    // runTest(128, 8);
    // runTest(128, 9);
    // runTest(128, 10);

    // runTest(256, 1);
    // runTest(256, 2);
    // runTest(256, 3);
    // runTest(256, 4);
    // runTest(256, 5);
    // runTest(256, 6);
    // runTest(256, 7);
    // runTest(256, 8);
    // runTest(256, 9);
    // runTest(256, 10);

#undef runTest

    if (rdp.verbose)
    {
        *g_logFile << "% best performance conf: " << bestKernelParams.BLOCK_THREADS 
                    << ", " << bestKernelParams.POINTS_PER_THREAD 
                    << ", " << bestKernelParams.avgMillis
                    << ", " << bestKernelParams.gigaBandwidth << "\n"; 
    }

    if (g_drawAllGraphs)
    {
        std::ostringstream graphName;
        graphName << typeid(T).name() << DIM 
            << "__" << rd::LoadModifierNameTraits<LOAD_MODIFIER>::name
            << "__" << rd::StoreModifierNameTraits<STORE_MODIFIER>::name
            << "__" << rd::DataMemoryLayoutNameTraits<MEM_LAYOUT>::name
            << "__" << rd::DataMemoryLayoutNameTraits<PRIVATE_MEM_LAYOUT>::name
            << "__" << rd::BlockTileIONameTraits<IO_BACKEND>::name
            << "__" << rdp.np << "p";

        rd::GraphDrawer<T> gDrawer;

        gDrawer.setXLabel("Liczba punktów na wątek.");
        gDrawer.setYLabel("GB/s");
        gDrawer.showLegend();
        // format %.0f means 0 digits after the decimal point to print
        gDrawer.sendCmd("set format x '%.0f'");

        gDrawer.startGraph(graphName.str());
        for (size_t k = 0; k < graphData.size(); ++k)
        {
            auto &graphLine = graphData[k];
            std::ostringstream cmd;
            // ($1*10) -> multiplies x values by 10
            // :xticlabels(1) -> use values from first column as x tic's labels
            // :xtic(1) has the same meaning
            cmd << " '-' u ($1*10):2:xtic(1) t 'rozmiar bloku: " << graphLine.first << "' w lp ls " << (k+1) % gDrawer.stylesCnt << " ";
            gDrawer.addPlotCmd(cmd.str(), graphLine.second.data(), rd::GraphDrawer<T>::LINE, graphLine.second.size() / 2);
        }

        gDrawer.endGraph();
    }

    std::cout << ">>>>>>> best performance conf: " << bestKernelParams.BLOCK_THREADS 
                << ", " << bestKernelParams.POINTS_PER_THREAD 
                << ", " << bestKernelParams.avgMillis
                << ", " << bestKernelParams.gigaBandwidth << std::endl; 

    return bestKernelParams;
}

//------------------------------------------------------------
//  TEST SPECIFIED VARIANTS
//------------------------------------------------------------

template <int DIM, typename T>
void test(rd::RDParams<T> &rdp,
          rd::RDSpiralParams<T> &rds)
{
    rdp.dim = DIM;
    std::vector<std::string> samplesDir{"../../examples/data/nd_segments/", "../../examples/data/spirals/"};
    rd::gpu::Samples<T> d_samplesSet(rdp, rds, samplesDir, DIM);

    std::cout << "Samples: " << std::endl;
    std::cout <<  "\t dimension: " << rdp.dim << std::endl;
    std::cout <<  "\t n_samples: " << rdp.np << std::endl;

    std::cout << "Spiral params: " << std::endl;
    if (DIM == 2 || DIM == 3) 
    {
        std::cout <<  "\t a: " << rds.a << std::endl;
        std::cout <<  "\t b: " << rds.b << std::endl;
    }
    else
    {
        std::cout <<  "\t seg length: " << rds.a << std::endl;
    }
    std::cout <<  "\t sigma: " << rds.sigma << std::endl; 

    T *d_inRowMajor, *d_inColMajor;
    T *d_out;

    // allocate containers
    checkCudaErrors(cudaMalloc((void**)&d_inRowMajor, rdp.np * DIM * sizeof(T)));
    checkCudaErrors(cudaMalloc((void**)&d_inColMajor, rdp.np * DIM * sizeof(T)));
    checkCudaErrors(cudaMalloc((void**)&d_out, rdp.np * DIM * sizeof(T)));

    #ifdef RD_DEBUG
        std::cout << "------- d_out addres range: [" << d_out << "," << d_out + rdp.np * DIM << "]\n";
    #endif

    T *h_inRowMajor = new T[rdp.np * DIM];
    T *h_inColMajor = new T[rdp.np * DIM];

    // initialize data
    checkCudaErrors(cudaMemcpy(d_inRowMajor, d_samplesSet.samples_, rdp.np * DIM * sizeof(T), cudaMemcpyDeviceToDevice));
    checkCudaErrors(cudaMemcpy(h_inRowMajor, d_samplesSet.samples_, rdp.np * DIM * sizeof(T), cudaMemcpyDeviceToHost));

    rd::transposeTable(h_inRowMajor, h_inColMajor, rdp.np, DIM);
    checkCudaErrors(cudaMemcpy(d_inColMajor, h_inColMajor, rdp.np * DIM * sizeof(T), cudaMemcpyHostToDevice));
    checkCudaErrors(cudaDeviceSynchronize());

    // sort results so we can compare them
    std::sort(h_inRowMajor, h_inRowMajor + rdp.np * DIM);
    std::sort(h_inColMajor, h_inColMajor + rdp.np * DIM);

    // set device heap size for dynamic vector allocations
    size_t devFreeMem, devTotalMem;
    cudaMemGetInfo(&devFreeMem, &devTotalMem);

    if (!g_deviceHeapLimitSet)
    {
        if (rdp.np * DIM * sizeof(T) * 10 > devFreeMem)
        {
            throw std::length_error("Insufficient device free memory available!");
        }
        std::cout << "-----     Allocating " << rdp.np * DIM * sizeof(T) * 10 / 1024 / 1024 << 
            "MB of heap storage from available " << devFreeMem / 1024 / 1024 << "MB device free mem" << std::endl;
        checkCudaErrors(cudaDeviceSetLimit(cudaLimitMallocHeapSize, rdp.np * DIM * sizeof(T) * 10));
        g_deviceHeapLimitSet = true;
    }

    //---------------------------------------------------
    // Prepare logFile if needed
    //---------------------------------------------------

    if (rdp.verbose)
    {
        std::ostringstream logFileName;
        // append device name to log file
        logFileName << g_devName << "_" << std::to_string(DIM) <<
             "D" << LOG_FILE_NAME_SUFFIX;

        std::string logFilePath = rd::findPath("timings/", logFileName.str());
        g_logFile = new std::ofstream(logFilePath.c_str(), std::ios::out | std::ios::app);
        if (g_logFile->fail())
        {
            throw std::logic_error("Couldn't open file: " + logFileName.str());
        }

        *g_logFile << "%" << rd::HLINE << std::endl;
        *g_logFile << "% " << typeid(T).name() << std::endl;
        *g_logFile << "%" << rd::HLINE << std::endl;
    }

    //---------------------------------------------------
    //               GPU LOAD & WRITE
    //---------------------------------------------------

    std::vector<KernelParametersConf> bestConfigurations;
    KernelParametersConf bestKernelParams;

    auto processResults = [&bestKernelParams](int graphSec, KernelParametersConf params)
    {
        if (params.gigaBandwidth > bestKernelParams.gigaBandwidth)
        {
            bestKernelParams = params;
        }
        if (g_drawGraphs)
        {
            g_bestPerf[graphSec].push_back(DIM);
            g_bestPerf[graphSec].push_back(params.gigaBandwidth);
        }
    };

    std::cout << rd::HLINE << "\n";

    bestKernelParams =  testBlockPointsPerThreadConf<DIM, cub::LOAD_LDG, cub::STORE_DEFAULT, rd::ROW_MAJOR, rd::ROW_MAJOR, rd::gpu::IO_BACKEND_CUB>(rdp, d_inRowMajor, d_out, h_inRowMajor, int(0), int(1));
    if (g_drawGraphs)
    {
        g_bestPerf[0].push_back(DIM);
        g_bestPerf[0].push_back(bestKernelParams.gigaBandwidth);
    }

    // processResults(1, testBlockPointsPerThreadConf<DIM, cub::LOAD_LDG, cub::STORE_DEFAULT, rd::ROW_MAJOR, rd::COL_MAJOR, rd::gpu::IO_BACKEND_CUB>(rdp, d_inRowMajor, d_out, h_inRowMajor, int(0), int(1)));
    // processResults(2, testBlockPointsPerThreadConf<DIM, cub::LOAD_LDG, cub::STORE_DEFAULT, rd::COL_MAJOR, rd::COL_MAJOR, rd::gpu::IO_BACKEND_CUB>(rdp, d_inColMajor, d_out, h_inColMajor, int(0), int(rdp.np)));
    // processResults(3, testBlockPointsPerThreadConf<DIM, cub::LOAD_LDG, cub::STORE_DEFAULT, rd::COL_MAJOR, rd::ROW_MAJOR, rd::gpu::IO_BACKEND_CUB>(rdp, d_inColMajor, d_out, h_inColMajor, int(0), int(rdp.np)));

    processResults(4, testBlockPointsPerThreadConf<DIM, cub::LOAD_LDG, cub::STORE_DEFAULT, rd::ROW_MAJOR, rd::ROW_MAJOR, rd::gpu::IO_BACKEND_TROVE>(rdp, d_inRowMajor, d_out, h_inRowMajor, int(0), int(1)));
    // processResults(5, testBlockPointsPerThreadConf<DIM, cub::LOAD_LDG, cub::STORE_DEFAULT, rd::ROW_MAJOR, rd::COL_MAJOR, rd::gpu::IO_BACKEND_TROVE>(rdp, d_inRowMajor, d_out, h_inRowMajor, int(0), int(1)));
    // processResults(6, testBlockPointsPerThreadConf<DIM, cub::LOAD_LDG, cub::STORE_DEFAULT, rd::COL_MAJOR, rd::COL_MAJOR, rd::gpu::IO_BACKEND_TROVE>(rdp, d_inColMajor, d_out, h_inColMajor, int(0), int(rdp.np)));
    // processResults(7, testBlockPointsPerThreadConf<DIM, cub::LOAD_LDG, cub::STORE_DEFAULT, rd::COL_MAJOR, rd::ROW_MAJOR, rd::gpu::IO_BACKEND_TROVE>(rdp, d_inColMajor, d_out, h_inColMajor, int(0), int(rdp.np)));

    std::cout << rd::HLINE << "\n";

    //---------------------------------------------------
    //  summarize results
    //---------------------------------------------------

    if (rdp.verbose)
    {
        *g_logFile << "\n% overall best conf: " 
            << "\n%avgMillis: \t\t" << bestKernelParams.avgMillis
            << "\n%gigaBandwidth: \t" << bestKernelParams.gigaBandwidth
            << "\n%block threads: \t" << bestKernelParams.BLOCK_THREADS
            << "\n%points per thread: \t" << bestKernelParams.POINTS_PER_THREAD
            << "\n%load modifier: \t" << rd::getLoadModifierName(bestKernelParams.LOAD_MODIFIER)
            << "\n%store modifier: \t" << rd::getStoreModifierName(bestKernelParams.STORE_MODIFIER)
            << "\n%mem layout: \t\t" << rd::getRDDataMemoryLayout(bestKernelParams.MEM_LAYOUT)
            << "\n%priv mem layout: \t" << rd::getRDDataMemoryLayout(bestKernelParams.PRIVATE_MEM_LAYOUT)
            << "\n%io backend: \t\t" << rd::getRDTileIOBackend(bestKernelParams.IO_BACKEND)
            << "\n%numPoints: \t\t" << rdp.np << "\n";
    }

    std::cout << ">>>>> overall best conf: \n%" 
        << "\n avgMillis: \t\t" << bestKernelParams.avgMillis
        << "\n gigaBandwidth: \t" << bestKernelParams.gigaBandwidth
        << "\n block threads: \t" << bestKernelParams.BLOCK_THREADS
        << "\n points per thread: \t" << bestKernelParams.POINTS_PER_THREAD
        << "\n load modifier: \t" << rd::getLoadModifierName(bestKernelParams.LOAD_MODIFIER)
        << "\n store modifier: \t" << rd::getStoreModifierName(bestKernelParams.STORE_MODIFIER)
        << "\n mem layout: \t\t" << rd::getRDDataMemoryLayout(bestKernelParams.MEM_LAYOUT)
        << "\n priv mem layout: \t" << rd::getRDDataMemoryLayout(bestKernelParams.PRIVATE_MEM_LAYOUT)
        << "\n io backend: \t\t" << rd::getRDTileIOBackend(bestKernelParams.IO_BACKEND)
        << "\n numPoints: \t\t" << rdp.np << "\n";

    //---------------------------------------------------
    // clean-up
    
    if (rdp.verbose)
    {
        g_logFile->close();
        delete g_logFile;
    }

    delete[] h_inRowMajor;
    delete[] h_inColMajor;

    checkCudaErrors(cudaFree(d_inRowMajor));
    checkCudaErrors(cudaFree(d_inColMajor));
    checkCudaErrors(cudaFree(d_out));
}

template <typename T>
std::string createFinalGraphDataFile()
{
    //------------------------------------------
    // create data file for drawing graph
    //------------------------------------------

    std::ostringstream graphDataFile;
    graphDataFile << typeid(T).name() << "_" << g_devName << "_graphData.dat";

    std::string filePath = rd::findPath("gnuplot_data/", graphDataFile.str());
    std::ofstream gdataFile(filePath.c_str(), std::ios::out | std::ios::trunc);
    if (gdataFile.fail())
    {
        throw std::logic_error("Couldn't open file: " + graphDataFile.str());
    }

    auto printData = [&gdataFile](std::vector<float> const &v, std::string secName)
    {
        gdataFile << "# [" << secName << "] \n";
        for (size_t i = 0; i < v.size()/2; ++i)
        {
            gdataFile << std::right << std::fixed << std::setw(5) << std::setprecision(1) <<
                v[2 * i] << " " << v[2 * i + 1] << "\n";
        }
        // two sequential blank records to reset $0 counter
        gdataFile << "\n\n";
    };

    printData(g_bestPerf[0], "ROW-ROW-(CUB)");
    printData(g_bestPerf[1], "ROW-COL-(CUB)");
    printData(g_bestPerf[2], "COL-COL-(CUB)");
    printData(g_bestPerf[3], "COL-ROW-(CUB)");
    printData(g_bestPerf[4], "ROW-ROW-(trove)");
    printData(g_bestPerf[5], "ROW-COL-(trove)");
    printData(g_bestPerf[6], "COL-COL-(trove)");
    printData(g_bestPerf[7], "COL-ROW-(trove)");

    gdataFile.close();
    return filePath;
}

template <typename T>
void drawFinalGraph(std::string graphDataFilePath)
{
        //------------------------------------------
        // drawing graph
        //------------------------------------------

        rd::GraphDrawer<float> gDrawer;
        std::ostringstream graphName;
        graphName << typeid(T).name() << "_" << g_devName << "_bandwidths.png";
        std::string filePath = rd::findPath("img/", graphName.str());

        gDrawer.sendCmd("set output '" + filePath + "'");
        gDrawer.setXLabel("Wymiar danych.");
        gDrawer.setYLabel("GB/s");

        gDrawer.sendCmd("set key right top");
        gDrawer.sendCmd("set style fill solid 0.95 border rgb 'grey30'");

        gDrawer.sendCmd("colStep = " + std::to_string(g_graphColStep));
        gDrawer.sendCmd("bs = 2 * colStep");
        gDrawer.sendCmd("nCol = " + std::to_string(g_graphNCol));
        gDrawer.sendCmd("groupStep = (nCol+1) * bs");
        gDrawer.sendCmd("nGroups = " + std::to_string(g_graphNGroups));
        gDrawer.sendCmd("offset = 9 * colStep");
        gDrawer.sendCmd("xEnd = offset + (nGroups-1) * groupStep + 9 * colStep + 4");

        gDrawer.sendCmd("set xrange [0:xEnd]");
        gDrawer.sendCmd("set xtics nomirror out ('2D' offset,'3D' offset + groupStep,"
             "'4D' offset + 2*groupStep, '5D' offset + 3*groupStep, '6D' offset + 4*groupStep)");
        gDrawer.sendCmd("dataFile = '" + graphDataFilePath + "'");

        std::ostringstream cmd;
        cmd << "plot dataFile i 0 u (offset + $0 * groupStep - 7 * colStep):2:(bs) t 'ROW-ROW (CUB)' w boxes ls 1,";
        cmd << "    ''        i 1 u (offset + $0 * groupStep - 5 * colStep):2:(bs) t 'ROW-COL (CUB)' w boxes ls 2,";
        cmd << "    ''        i 2 u (offset + $0 * groupStep - 3 * colStep):2:(bs) t 'COL-COL (CUB)' w boxes ls 3,";
        cmd << "    ''        i 3 u (offset + $0 * groupStep - 1 * colStep):2:(bs) t 'COL-ROW (CUB)' w boxes ls 4,";
        cmd << "    ''        i 4 u (offset + $0 * groupStep + 1 * colStep):2:(bs) t 'ROW-ROW (trove)' w boxes ls 5,";
        cmd << "    ''        i 5 u (offset + $0 * groupStep + 3 * colStep):2:(bs) t 'ROW-COL (trove)' w boxes ls 6,";
        cmd << "    ''        i 6 u (offset + $0 * groupStep + 5 * colStep):2:(bs) t 'COL-COL (trove)' w boxes ls 7,";
        cmd << "    ''        i 7 u (offset + $0 * groupStep + 7 * colStep):2:(bs) t 'COL-ROW (trove)' w boxes ls 8,";
        cmd << "    ''        i 0 u (offset + $0 * groupStep - 7 * colStep):($2 + 0.6):2 notitle w labels rotate by 70 left,";
        cmd << "    ''        i 1 u (offset + $0 * groupStep - 5 * colStep):($2 + 0.6):2 notitle w labels rotate by 70 left,";
        cmd << "    ''        i 2 u (offset + $0 * groupStep - 3 * colStep):($2 + 0.6):2 notitle w labels rotate by 70 left,";
        cmd << "    ''        i 3 u (offset + $0 * groupStep - 1 * colStep):($2 + 0.6):2 notitle w labels rotate by 70 left,";
        cmd << "    ''        i 4 u (offset + $0 * groupStep + 1 * colStep):($2 + 0.6):2 notitle w labels rotate by 70 left,";
        cmd << "    ''        i 5 u (offset + $0 * groupStep + 3 * colStep):($2 + 0.6):2 notitle w labels rotate by 70 left,";
        cmd << "    ''        i 6 u (offset + $0 * groupStep + 5 * colStep):($2 + 0.6):2 notitle w labels rotate by 70 left,";
        cmd << "    ''        i 7 u (offset + $0 * groupStep + 7 * colStep):($2 + 0.6):2 notitle w labels rotate by 70 left ";

        gDrawer.sendCmd(cmd.str());
}

int main(int argc, char const **argv)
{

    rd::RDParams<double> dParams;
    rd::RDSpiralParams<double> dSParams;
    rd::RDParams<float> fParams;
    rd::RDSpiralParams<float> fSParams;

    //-----------------------------------------------------------------

    // Initialize command line
    rd::CommandLineArgs args(argc, argv);
    if (args.CheckCmdLineFlag("help")) 
    {
        printf("%s \n"
            "\t\t[--np=<P size>]\n"
            "\t\t[--a=<spiral param>]\n"
            "\t\t[--b=<spiral param>]\n"
            "\t\t[--s=<spiral noise sigma>]\n"
            "\t\t[--d=<device id>]\n"
            "\t\t[--v <verbose>]\n"
            "\t\t[--f=<file name to load>]\n"
            "\t\t[--g <draw graphs>]\n"
            "\t\t[--ga <draw all graphs (a lot)>]\n"
            "\n", argv[0]);
        exit(0);
    }

    if (args.CheckCmdLineFlag("f"))
    {
        args.GetCmdLineArgument("f", fSParams.file);
        args.GetCmdLineArgument("f", dSParams.file);
        fSParams.loadFromFile = true;
        dSParams.loadFromFile = true;
    }
    else
    {
        args.GetCmdLineArgument("np", dParams.np);
        args.GetCmdLineArgument("np", fParams.np);

        if (args.CheckCmdLineFlag("a")) 
        {
            args.GetCmdLineArgument("a", fSParams.a);
            args.GetCmdLineArgument("a", dSParams.a);
        }
        if (args.CheckCmdLineFlag("b")) 
        {
            args.GetCmdLineArgument("b", fSParams.b);
            args.GetCmdLineArgument("b", dSParams.b);
        }
        if (args.CheckCmdLineFlag("s")) 
        {
            args.GetCmdLineArgument("s", fSParams.sigma);
            args.GetCmdLineArgument("s", dSParams.sigma);
        }
    }
    if (args.CheckCmdLineFlag("d")) 
    {
        args.GetCmdLineArgument("d", fParams.devId);
        args.GetCmdLineArgument("d", dParams.devId);
    }
    if (args.CheckCmdLineFlag("v")) 
    {
        fParams.verbose = true;
        dParams.verbose = true;
    }
    if (args.CheckCmdLineFlag("g")) 
    {
        g_drawGraphs = true;
    }
    if (args.CheckCmdLineFlag("ga")) 
    {
        g_drawAllGraphs = true;
        g_drawGraphs = true;
    }

    checkCudaErrors(deviceInit(fParams.devId));

    // set device name for logging and drawing purposes
    fParams.devId = (fParams.devId != -1) ? fParams.devId : 0;
    cudaDeviceProp devProp;
    checkCudaErrors(cudaGetDeviceProperties(&devProp, fParams.devId));
    g_devName = devProp.name;

    if (g_drawGraphs)
    {
        // initialize storage for graph data
        g_bestPerf = std::vector<std::vector<float>>(g_graphNCol);
    }

    //-----------------------------------------
    //  TESTS
    //-----------------------------------------

    // std::cout << "DOUBLE 6D: " << std::endl;
    // test<6>(dParams, dSParams);
    // std::cout << rd::HLINE << std::endl;
    // std::cout << "DOUBLE 5D: " << std::endl;
    // test<5>(dParams, dSParams);
    // std::cout << rd::HLINE << std::endl;
    // std::cout << "DOUBLE 4D: " << std::endl;
    // test<4>(dParams, dSParams);
    // std::cout << rd::HLINE << std::endl;
    // std::cout << "DOUBLE 3D: " << std::endl;
    // test<3>(dParams, dSParams);
    // std::cout << rd::HLINE << std::endl;
    // std::cout << "DOUBLE 2D: " << std::endl;
    // test<2>(dParams, dSParams);
    // std::cout << rd::HLINE << std::endl;

    // if (g_drawGraphs)
    // {
    //     drawFinalGraph<double>(createFinalGraphDataFile<double>());

    //     g_bestPerf.clear();
    //     g_bestPerf = std::vector<std::vector<float>>(g_graphNCol);
    // }

    // std::cout << "FLOAT 6D: " << std::endl;
    // test<6>(fParams, fSParams);
    // std::cout << rd::HLINE << std::endl;
    // std::cout << "FLOAT 5D: " << std::endl;
    // test<5>(fParams, fSParams);
    // std::cout << rd::HLINE << std::endl;
    // std::cout << "FLOAT 4D: " << std::endl;
    // test<4>(fParams, fSParams);
    // std::cout << rd::HLINE << std::endl;
    std::cout << "FLOAT 3D: " << std::endl;
    test<3>(fParams, fSParams);
    std::cout << rd::HLINE << std::endl;
    // std::cout << "FLOAT 2D: " << std::endl;
    // test<2>(fParams, fSParams);
    // std::cout << rd::HLINE << std::endl;

    // if (g_drawGraphs)
    // {
    //     drawFinalGraph<float>(createFinalGraphDataFile<float>());

    //     g_bestPerf.clear();
    // }

    checkCudaErrors(deviceReset());

    std::cout << "END!" << std::endl;
    return 0;
}
