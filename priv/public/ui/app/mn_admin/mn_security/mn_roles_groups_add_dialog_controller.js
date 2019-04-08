(function () {
  "use strict";

  angular
    .module("mnRolesGroups")
    .controller("mnRolesGroupsAddDialogController", mnRolesGroupsAddDialogController);

  function mnRolesGroupsAddDialogController($scope, mnUserRolesService, $uibModalInstance, mnPromiseHelper, rolesGroup, isLdapEnabled, $timeout) {
    var vm = this;
    vm.rolesGroup = _.clone(rolesGroup) || {};
    vm.rolesGroupID = vm.rolesGroup.id || 'New';
    vm.save = save;
    vm.isEditingMode = !!rolesGroup;
    vm.isLdapEnabled = isLdapEnabled;
    vm.selectedRoles = {};

    vm.focusError = false;

    function save() {
      if (vm.form.$invalid) {
        vm.focusError = true;
        return;
      }

      //example of the inсoming role
      //All Buckets (*)|Query and Index Services|query_insert[*]
      var roles = [];
      _.forEach(vm.selectedRoles, function (value, key) {
        if (value) {
          var path = key.split("|");
          roles.push(path[path.length - 1]);
        }
      });

      mnPromiseHelper(vm, mnUserRolesService.putRolesGroup(vm.rolesGroup, roles, vm.isEditingMode), $uibModalInstance)
        .showGlobalSpinner()
        .catchErrors(function (errors) {
          vm.focusError = !!errors;
          vm.errors = errors;
        })
        .broadcast("reloadRolesGroupsPoller")
        .closeOnSuccess()
        .showGlobalSuccess("User saved successfully!");
    }
  }
})();