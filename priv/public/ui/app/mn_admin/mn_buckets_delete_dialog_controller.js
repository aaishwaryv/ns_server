export default mnBucketsDeleteDialogController;

function mnBucketsDeleteDialogController($uibModalInstance, bucket, mnPromiseHelper, mnBucketsDetailsService) {
  var vm = this;
  vm.doDelete = doDelete;
  vm.bucketName = bucket.name;

  function doDelete() {
    var promise = mnBucketsDetailsService.deleteBucket(bucket);
    mnPromiseHelper(vm, promise, $uibModalInstance)
      .showGlobalSpinner()
      .catchGlobalErrors()
      .closeFinally()
      .showGlobalSuccess("Bucket deleted successfully!");
  }
}
