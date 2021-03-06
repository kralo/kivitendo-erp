# This file has been auto-generated. Do not modify it; it will be overwritten
# by rose_auto_create_model.pl automatically.
package SL::DB::PriceFactor;

use strict;

use base qw(SL::DB::Object);

__PACKAGE__->meta->table('price_factors');

__PACKAGE__->meta->columns(
  id          => { type => 'integer', not_null => 1, sequence => 'id' },
  description => { type => 'text' },
  factor      => { type => 'numeric', precision => 5, scale => 15 },
  sortkey     => { type => 'integer' },
);

__PACKAGE__->meta->primary_key_columns([ 'id' ]);

# __PACKAGE__->meta->initialize;

1;
;
