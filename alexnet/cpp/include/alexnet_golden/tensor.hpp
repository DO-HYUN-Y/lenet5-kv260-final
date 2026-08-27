#pragma once

#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace alexnet::golden {

template <typename T>
class Tensor4D {
 public:
  Tensor4D() = default;

  Tensor4D(int n, int c, int h, int w)
      : n_(n), c_(c), h_(h), w_(w), data_(checked_size(n, c, h, w)) {}

  Tensor4D(int n, int c, int h, int w, std::vector<T> data)
      : n_(n), c_(c), h_(h), w_(w), data_(std::move(data)) {
    if (data_.size() != checked_size(n, c, h, w)) {
      throw std::invalid_argument("Tensor4D data size does not match NCHW shape");
    }
  }

  int n() const { return n_; }
  int c() const { return c_; }
  int h() const { return h_; }
  int w() const { return w_; }
  std::size_t size() const { return data_.size(); }

  T& at(int n, int c, int h, int w) { return data_.at(offset(n, c, h, w)); }
  const T& at(int n, int c, int h, int w) const {
    return data_.at(offset(n, c, h, w));
  }

  std::vector<T>& data() { return data_; }
  const std::vector<T>& data() const { return data_; }

 private:
  static std::size_t checked_size(int n, int c, int h, int w) {
    if (n <= 0 || c <= 0 || h <= 0 || w <= 0) {
      throw std::invalid_argument("Tensor4D dimensions must be positive");
    }
    return static_cast<std::size_t>(n) * static_cast<std::size_t>(c) *
           static_cast<std::size_t>(h) * static_cast<std::size_t>(w);
  }

  std::size_t offset(int n, int c, int h, int w) const {
    if (n < 0 || n >= n_ || c < 0 || c >= c_ || h < 0 || h >= h_ ||
        w < 0 || w >= w_) {
      throw std::out_of_range("Tensor4D NCHW index out of range");
    }
    return (((static_cast<std::size_t>(n) * c_ + c) * h_ + h) * w_ + w);
  }

  int n_ = 0;
  int c_ = 0;
  int h_ = 0;
  int w_ = 0;
  std::vector<T> data_;
};

template <typename T>
class Matrix {
 public:
  Matrix() = default;

  Matrix(int rows, int cols)
      : rows_(rows), cols_(cols), data_(checked_size(rows, cols)) {}

  Matrix(int rows, int cols, std::vector<T> data)
      : rows_(rows), cols_(cols), data_(std::move(data)) {
    if (data_.size() != checked_size(rows, cols)) {
      throw std::invalid_argument("Matrix data size does not match shape");
    }
  }

  int rows() const { return rows_; }
  int cols() const { return cols_; }
  std::size_t size() const { return data_.size(); }

  T& at(int row, int col) { return data_.at(offset(row, col)); }
  const T& at(int row, int col) const { return data_.at(offset(row, col)); }

  std::vector<T>& data() { return data_; }
  const std::vector<T>& data() const { return data_; }

 private:
  static std::size_t checked_size(int rows, int cols) {
    if (rows <= 0 || cols <= 0) {
      throw std::invalid_argument("Matrix dimensions must be positive");
    }
    return static_cast<std::size_t>(rows) * static_cast<std::size_t>(cols);
  }

  std::size_t offset(int row, int col) const {
    if (row < 0 || row >= rows_ || col < 0 || col >= cols_) {
      throw std::out_of_range("Matrix index out of range");
    }
    return static_cast<std::size_t>(row) * cols_ + col;
  }

  int rows_ = 0;
  int cols_ = 0;
  std::vector<T> data_;
};

using TensorI8 = Tensor4D<std::int8_t>;
using TensorI32 = Tensor4D<std::int32_t>;
using MatrixI8 = Matrix<std::int8_t>;
using MatrixI32 = Matrix<std::int32_t>;

}  // namespace alexnet::golden
