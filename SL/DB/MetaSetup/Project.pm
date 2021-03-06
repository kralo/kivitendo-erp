# This file has been auto-generated. Do not modify it; it will be overwritten
# by rose_auto_create_model.pl automatically.
package SL::DB::Project;

use strict;

use base qw(SL::DB::Object);

__PACKAGE__->meta->table('project');

__PACKAGE__->meta->columns(
  id            => { type => 'integer', not_null => 1, sequence => 'id' },
  projectnumber => { type => 'text' },
  description   => { type => 'text' },
  itime         => { type => 'timestamp', default => 'now()' },
  mtime         => { type => 'timestamp' },
  active        => { type => 'boolean', default => 'true' },
  customer_id   => { type => 'integer' },
  type          => { type => 'text' },
  valid         => { type => 'boolean', default => 'true' },
);

__PACKAGE__->meta->primary_key_columns([ 'id' ]);

__PACKAGE__->meta->unique_keys([ 'projectnumber' ]);

__PACKAGE__->meta->allow_inline_column_values(1);

__PACKAGE__->meta->foreign_keys(
  customer => {
    class       => 'SL::DB::Customer',
    key_columns => { customer_id => 'id' },
  },
);

# __PACKAGE__->meta->initialize;

1;
;
