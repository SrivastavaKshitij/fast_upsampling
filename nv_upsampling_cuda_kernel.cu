#include <type_traits>

#include <ATen/ATen.h>

#include "bilinear.h"

#include <cuda.h>
#include <cuda_runtime.h>

template <typename scalar_t, typename std::enable_if<std::is_same<c10::Half, scalar_t>::value>::type* = nullptr>
__device__ __forceinline__
void fastSpecializedAtomicAdd(scalar_t* tensor,
                                  int index, int numel,
                                  scalar_t value) {


  if (index < numel - 1) {
    __half2 value2;

    if (index % 2 == 0 && index < (numel - 1)) {
      value2.x = value;
      value2.y = __int2half_rz(0);
    }
    if (index % 2 == 1) {
      value2.x = __int2half_rz(0);
      value2.y = value;
    }

    atomicAdd(reinterpret_cast<__half2*>(tensor) + index/2, value2);

    } else {

     atomicAdd(reinterpret_cast<__half*>(tensor) + index, static_cast<__half>(value));
   }
}

template <typename scalar_t, typename std::enable_if<!std::is_same<c10::Half, scalar_t>::value>::type* = nullptr>
__device__ __forceinline__ void fastSpecializedAtomicAdd(scalar_t* tensor,
                                  int index, int numel,
                                  scalar_t value) {

  atomicAdd(tensor + index, value);

}

template <class scalar_t>
__device__  __forceinline__ void fastAtomicAdd(scalar_t* __restrict__ tensor,
    int index, int numel, scalar_t value) {


    fastSpecializedAtomicAdd(tensor, index, numel, value);

}

// https://github.com/pytorch/pytorch/blob/master/aten/src/THCUNN/TemporalUpSamplingLinear.cu

__device__ __forceinline__ int idx(
    const int n,
    const int num_channels,
    const int c,
    const int height,
    const int width,
    const int y,
    const int x) {
  return ((n * num_channels + c) * height + y) * width + x;
}

// input is X, output is Y
template <typename scalar_t>
__global__ void bilinearForwardKernel(
    const int output_size,
    const int num_channels,
    const int input_height,
    const int input_width,
    const int output_height,
    const int output_width,
    const scalar_t* const  __restrict__ X,
    scalar_t* const __restrict__ Y) {

    const float height_scale = 1.0f * output_height / input_height;
    const float width_scale = 1.0f * output_width / input_width;

  for (size_t index = blockDim.x * blockIdx.x + threadIdx.x;
       index < output_size; index += blockDim.x * gridDim.x) {

    int indexTemp = index;
    const int out_x = indexTemp % output_width;
    indexTemp /= output_width;
    const int out_y = indexTemp % output_height;
    indexTemp /= output_height;
    const int c = indexTemp % num_channels;
    indexTemp /= num_channels;
    const int n = indexTemp;

    const int in_y = fminf(out_y / height_scale, input_height - 1);
    const int in_x = fminf(out_x / width_scale, input_width - 1);

    const float rheight =
        output_height > 1 ? (input_height - 1.f) / (output_height - 1.f) : 0.f;
    const float rwidth =
        output_width > 1 ? (input_width - 1.f) / (output_width - 1.f) : 0.f;

    // Compute Y axis lambdas
    const float h1r = rheight * out_y;
    const int h1 = static_cast<int>(h1r);
    const int h1p = (h1 < input_height - 1) ? 1 : 0;
    const float h1lambda = h1r - h1;
    const float h0lambda = 1.f - h1lambda;

    // Compute X axis lambdas
    const float w1r = rwidth * out_x;
    const int w1 = static_cast<int>(w1r);
    const int w1p = (w1 < input_width - 1) ? 1 : 0;
    const float w1lambda = w1r - w1;
    const float w0lambda = 1.f - w1lambda;

    Y[index] =
        static_cast<scalar_t>(h0lambda *
             (w0lambda *
                  __ldg(&X[idx(
                      n, num_channels, c, input_height, input_width, h1, w1)]) +
              w1lambda *
                  __ldg(&X[idx(
                      n,
                      num_channels,
                      c,
                      input_height,
                      input_width,
                      h1,
                      w1 + w1p)])) +
         h1lambda *
             (w0lambda *
                  __ldg(&X[idx(
                      n,
                      num_channels,
                      c,
                      input_height,
                      input_width,
                      h1 + h1p,
                      w1)]) +
              w1lambda *
                  __ldg(&X[idx(
                      n,
                      num_channels,
                      c,
                      input_height,
                      input_width,
                      h1 + h1p,
                      w1 + w1p)])));
  }
}

// input is dY, output is dX
template <typename scalar_t>
__global__ void bilinearBackwardKernel(
    const int input_size,
    const int num_channels,
    const int input_height,
    const int input_width,
    const int output_height,
    const int output_width,
    const scalar_t* const __restrict__ dY,
    scalar_t* const __restrict__ dX) {

    const float height_scale = 1.0f * output_height / input_height;
    const float width_scale = 1.0f * output_width / input_width;

    for (size_t index = blockDim.x * blockIdx.x + threadIdx.x;
         index < input_size; index += blockDim.x * gridDim.x) {

    int indexTemp = index;
    const int in_x = indexTemp % input_width;
    indexTemp /= input_width;
    const int in_y = indexTemp % input_height;
    indexTemp /= input_height;
    const int c = indexTemp % num_channels;
    indexTemp /= num_channels;
    const int n = indexTemp;

    const int out_y = fminf(in_y / height_scale, output_height - 1);
    const int out_x = fminf(in_x / width_scale, output_width - 1);

    const float rheight =
        output_height > 1 ? (output_height - 1.f) / (input_height - 1.f) : 0.f;
    const float rwidth =
        output_width > 1 ? (output_width - 1.f) / (input_width - 1.f) : 0.f;

    // Compute Y axis lambdas
    const float h1r = rheight * in_y;
    const int h1 = static_cast<int>(h1r);
    const int h1p = (h1 < output_height - 1) ? 1 : 0;
    const float h1lambda = h1r - h1;
    const float h0lambda = 1.f - h1lambda;

    // Compute X axis lambdas
    const float w1r = rwidth * in_x;
    const int w1 = static_cast<int>(w1r);
    const int w1p = (w1 < output_width - 1) ? 1 : 0;
    const float w1lambda = w1r - w1;
    const float w0lambda = 1.f - w1lambda;

    const scalar_t dYi = __ldg(&dY[index]);

    const int out_numel = input_size / (input_height * input_width) * output_height * output_width;

/*
__global__ void bilinearBackwardKernel(
    const int input_size,
    const int num_channels,
    const int input_height,
    const int input_width,
    const int output_height,
    const int output_width,
    const scalar_t* const __restrict__ dY,
    scalar_t* const __restrict__ dX) {
*/

      // TODO: add other three cases

      fastAtomicAdd<scalar_t>(
          dX, 
          idx(n, num_channels, c, output_height, output_width, h1, w1),
          out_numel,
          static_cast<scalar_t>(h0lambda * w0lambda * dYi)
      );

      fastAtomicAdd<scalar_t>(
        dX,
        idx(n, num_channels, c, output_height, output_width, h1, w1 + w1p),
        out_numel,
        static_cast<scalar_t>(h0lambda * w1lambda * dYi)
      );

      fastAtomicAdd<scalar_t>(
        dX,
        idx(n, num_channels, c, output_height, output_width, h1 + h1p, w1),
        out_numel,
        static_cast<scalar_t>(h1lambda * w0lambda * dYi)
      );

      fastAtomicAdd<scalar_t>(
        dX,
        idx(
            n,
            num_channels,
            c,
            output_height,
            output_width,
            h1 + h1p,
            w1 + w1p),
        out_numel,
        static_cast<scalar_t>(h1lambda * w1lambda * dYi)
      );


/*
      atomicAdd(
          &dX[idx(n, num_channels, c, output_height, output_width, h1, w1)],
          static_cast<scalar_t>(h0lambda * w0lambda * dYi));
      atomicAdd(
          &dX[idx(n, num_channels, c, output_height, output_width, h1, w1 + w1p)],
          static_cast<scalar_t>(h0lambda * w1lambda * dYi));
      atomicAdd(
          &dX[idx(n, num_channels, c, output_height, output_width, h1 + h1p, w1)],
          static_cast<scalar_t>(h1lambda * w0lambda * dYi));
      atomicAdd(
        &dX[idx(
            n,
            num_channels,
            c,
            output_height,
            output_width,
            h1 + h1p,
            w1 + w1p)],
        static_cast<scalar_t>(h1lambda * w1lambda * dYi));

 */

  }
}

/*
template <typename scalar_t>
void printType() {
  if (std::is_same<float, scalar_t>::value) {
      std::cout << "\n\nfwd float \n\n" << std::endl;
  } else if (std::is_same<c10::Half, scalar_t>::value) {
      std::cout << "\n\nfwd half \n\n" << std::endl;
  } else if (std::is_same<double, scalar_t>::value) {
      std::cout << "\n\nfwd double \n\n" << std::endl;
  } else {
    std::cout << "\n\nfwd something else \n\n" << std::endl;
  }

}
*/

at::Tensor bilinear_cuda_forward(at::Tensor& in, const int new_h, const int new_w) {

  // TODO: grid
  // TODO: block
  // TODO: make sure to specialize for half2 case

  // TODO: input dimensions

  // TODO: create new tensor here

  const int nIn = in.size(0);
  const int cIn = in.size(1);
  const int hIn = in.size(2);
  const int wIn = in.size(3);

  at::Tensor out = at::empty({nIn, cIn, new_h, new_w}, in.options());

  const int outSize = nIn * cIn * new_h * new_w;
  const dim3 block(1024);
  const dim3 grid((outSize + block.x - 1) / block.x);

/*
  AT_DISPATCH_FLOATING_TYPES_AND_HALF(in.type(), "foo", ([&]
   {
     printType<scalar_t>();

   }));
*/

  AT_DISPATCH_FLOATING_TYPES_AND_HALF(in.type(), "bilinearForwardKernel", ([&]
    {
     
        bilinearForwardKernel<scalar_t><<<grid, block>>>(
                                        out.numel(),
                                        cIn,
                                        hIn,
                                        wIn,
                                        new_h,
                                        new_w,
                                        in.data<scalar_t>(),
                                        out.data<scalar_t>()
                                      ); 

    }));

    AT_CHECK(cudaGetLastError() == cudaSuccess,
          "issue with bilinearForwardKernel, CUDA code ",
          cudaGetLastError());

  return out; 
}

at::Tensor bilinear_cuda_backward(at::Tensor& in, const int out_h, const int out_w) {

  const int nIn = in.size(0);
  const int cIn = in.size(1);
  const int hIn = in.size(2);
  const int wIn = in.size(3);

  at::Tensor out = at::empty({nIn, cIn, out_h, out_w}, in.options());

  const int inSize = nIn * cIn * hIn * wIn;
  const dim3 block(1024);
  const dim3 grid((inSize + block.x - 1) / block.x);

/*
template <typename scalar_t>
__global__ void bilinearBackwardKernel(
    const int input_size,
    const int num_channels,
    const int input_height,
    const int input_width,
    const int output_height,
    const int output_width,
    const float height_scale,
    const float width_scale,
    const scalar_t* const __restrict__ dY,
    scalar_t* const __restrict__ dX) {

*/

  // AT_DISPATCH_FLOATING_TYPES_AND_HALF

  AT_DISPATCH_FLOATING_TYPES_AND_HALF(in.type(), "bilinearBackwardKernel", ([&]
    {

        bilinearBackwardKernel<scalar_t><<<grid, block>>>(
                                        in.numel(),
                                        cIn,
                                        hIn,
                                        wIn,
                                        out_h,
                                        out_w,
                                        in.data<scalar_t>(),
                                        out.data<scalar_t>()
                                      ); 

    }));

    AT_CHECK(cudaGetLastError() == cudaSuccess,
          "issue with bilinearForwardKernel, CUDA code ",
          cudaGetLastError());

    return out;
}
