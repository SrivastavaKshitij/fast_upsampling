#include <torch/extension.h>

#include "bilinear.h"

#define CHECK_CUDA(x) AT_ASSERTM(x.type().is_cuda(), #x " must be a CUDA tensor")
#define CHECK_CONTIGUOUS(x) AT_ASSERTM(x.is_contiguous(), #x " must be contiguous")
#define CHECK_INPUT(x) CHECK_CUDA(x); CHECK_CONTIGUOUS(x)

at::Tensor bilinear_forward(at::Tensor& z, const int new_h, const int new_w) {
  CHECK_INPUT(z);
  return bilinear_cuda_forward(z, new_h, new_w);
}

at::Tensor bilinear_backward(at::Tensor& z, const int orig_h, const int orig_w) {
  CHECK_INPUT(z);
  return bilinear_cuda_backward(z, orig_h, orig_w);
}


PYBIND11_MODULE(TORCH_EXTENSION_NAME, m) {
  m.def("bilinear_forward", &bilinear_forward, "bilinear forward");
  m.def("bilinear_backward", &bilinear_backward, "bilinear backward");
}
