package SL::DB::Bin;

use strict;

use SL::DB::MetaSetup::Bin;

__PACKAGE__->meta->initialize;

__PACKAGE__->meta->make_manager_class;

1;
