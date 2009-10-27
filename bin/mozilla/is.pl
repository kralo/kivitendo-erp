#=====================================================================
# LX-Office ERP
# Copyright (C) 2004
# Based on SQL-Ledger Version 2.1.9
# Web http://www.lx-office.org
#
#=====================================================================
# SQL-Ledger Accounting
# Copyright (c) 1998-2002
#
#  Author: Dieter Simader
#   Email: dsimader@sql-ledger.org
#     Web: http://www.sql-ledger.org
#
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
#======================================================================
#
# Inventory invoicing module
#
#======================================================================

use SL::FU;
use SL::IS;
use SL::PE;
use Data::Dumper;
use List::Util qw(max sum);

require "bin/mozilla/io.pl";
require "bin/mozilla/invoice_io.pl";
require "bin/mozilla/arap.pl";
require "bin/mozilla/drafts.pl";

use strict;

my $edit;
my $payment;
my $print_post;

1;

# end of main

sub add {
  $main::lxdebug->enter_sub();

  my $form     = $main::form;
  my $locale   = $main::locale;

  $main::auth->assert('invoice_edit');

  return $main::lxdebug->leave_sub() if (load_draft_maybe());

  if ($form->{type} eq "credit_note") {
    $form->{title} = $locale->text('Add Credit Note');

    if ($form->{storno}) {
      $form->{title} = $locale->text('Add Storno Credit Note');
    }
  } else {
    $form->{title} = $locale->text('Add Sales Invoice');

  }


  $form->{callback} = "$form->{script}?action=add&type=$form->{type}" unless $form->{callback};

  $form->{jsscript} = "date";

  &invoice_links;
  &prepare_invoice;
  &display_form;

  $main::lxdebug->leave_sub();
}

sub edit {
  $main::lxdebug->enter_sub();

  my $form     = $main::form;
  my $locale   = $main::locale;

  $main::auth->assert('invoice_edit');

  # show history button
  $form->{javascript} = qq|<script type="text/javascript" src="js/show_history.js"></script>|;
  #/show hhistory button

  if ($form->{type} eq "credit_note") {
    $form->{title} = $locale->text('Edit Credit Note');
    $form->{title} = $locale->text('Edit Storno Credit Note') if $form->{storno};
  } else {
    $form->{title} = $locale->text('Edit Sales Invoice');
    $form->{title} = $locale->text('Edit Storno Invoice')     if $form->{storno};
  }

  my ($language_id, $printer_id);
  if ($form->{print_and_post}) {
    $form->{action}   = "print";
    $form->{resubmit} = 1;
    $language_id = $form->{language_id};
    $printer_id = $form->{printer_id};
  }
  &invoice_links;
  &prepare_invoice;
  if ($form->{print_and_post}) {
    $form->{language_id} = $language_id;
    $form->{printer_id} = $printer_id;
  }

  &display_form;

  $main::lxdebug->leave_sub();
}

sub invoice_links {
  $main::lxdebug->enter_sub();

  my $form     = $main::form;
  my %myconfig = %main::myconfig;

  $main::auth->assert('invoice_edit');

  $form->{vc} = 'customer';

  # create links
  $form->{webdav}   = $main::webdav;
  $form->{lizenzen} = $main::lizenzen;

  $form->create_links("AR", \%myconfig, "customer");

  if ($form->{all_customer}) {
    unless ($form->{customer_id}) {
      $form->{customer_id} = $form->{all_customer}->[0]->{id};
      $form->{salesman_id} = $form->{all_customer}->[0]->{salesman_id};
    }
  }

  $form->backup_vars(qw(payment_id language_id taxzone_id salesman_id taxincluded cp_id intnotes id shipto_id));

  IS->get_customer(\%myconfig, \%$form);

  #quote all_customer Bug 133
  foreach my $ref (@{ $form->{all_customer} }) {
    $ref->{name} = $form->quote($ref->{name});
  }

  $form->restore_vars(qw(id));

  IS->retrieve_invoice(\%myconfig, \%$form);
  $form->restore_vars(qw(payment_id language_id taxzone_id intnotes cp_id shipto_id));
  $form->restore_vars(qw(taxincluded)) if $form->{id};
  $form->restore_vars(qw(salesman_id)) if $main::editing;

  # build vendor/customer drop down comatibility... don't ask
  if (@{ $form->{"all_customer"} }) {
    $form->{"selectcustomer"} = 1;
    $form->{customer}         = qq|$form->{customer}--$form->{"customer_id"}|;
  }

  $form->{oldcustomer} = "$form->{customer}--$form->{customer_id}";
  $form->{selectcustomer} = 1;

  # departments
#  if ($form->{all_departments}) {
#    $form->{selectdepartment} = "<option>\n";
#    $form->{department}       = "$form->{department}--$form->{department_id}";
#
#    map {
#      $form->{selectdepartment} .= "<option>$_->{description}--$_->{id}</option>\n"
#    } @{ $form->{all_departments} };
#  }

  $form->{employee} = "$form->{employee}--$form->{employee_id}";

  # forex
  $form->{forex} = $form->{exchangerate};
  my $exchangerate = ($form->{exchangerate}) ? $form->{exchangerate} : 1;

  foreach my $key (keys %{ $form->{AR_links} }) {
    foreach my $ref (@{ $form->{AR_links}{$key} }) {
      $form->{"select$key"} .= "<option>$ref->{accno}--$ref->{description}</option>\n";
    }

    if ($key eq "AR_paid") {
      next unless $form->{acc_trans}{$key};
      for my $i (1 .. scalar @{ $form->{acc_trans}{$key} }) {
        $form->{"AR_paid_$i"}      = "$form->{acc_trans}{$key}->[$i-1]->{accno}--$form->{acc_trans}{$key}->[$i-1]->{description}";

        # reverse paid
        $form->{"paid_$i"}         = $form->{acc_trans}{$key}->[$i - 1]->{amount} * -1;
        $form->{"datepaid_$i"}     = $form->{acc_trans}{$key}->[$i - 1]->{transdate};
        $form->{"exchangerate_$i"} = $form->{acc_trans}{$key}->[$i - 1]->{exchangerate};
        $form->{"forex_$i"}        = $form->{"exchangerate_$i"};
        $form->{"source_$i"}       = $form->{acc_trans}{$key}->[$i - 1]->{source};
        $form->{"memo_$i"}         = $form->{acc_trans}{$key}->[$i - 1]->{memo};

        $form->{paidaccounts} = $i;
      }
    } else {
      $form->{$key} = "$form->{acc_trans}{$key}->[0]->{accno}--$form->{acc_trans}{$key}->[0]->{description}";
    }
  }

  $form->{paidaccounts} = 1 unless (exists $form->{paidaccounts});

  $form->{AR} = $form->{AR_1} unless $form->{id};

  $form->{locked} = ($form->datetonum($form->{invdate},  \%myconfig)
                  <= $form->datetonum($form->{closedto}, \%myconfig));

  $main::lxdebug->leave_sub();
}

sub prepare_invoice {
  $main::lxdebug->enter_sub();

  my $form     = $main::form;
  my %myconfig = %main::myconfig;

  $main::auth->assert('invoice_edit');

  if ($form->{type} eq "credit_note") {
    $form->{type}     = "credit_note";
    $form->{formname} = "credit_note";
  } else {
    $form->{type}     = "invoice";
    $form->{formname} = "invoice";
  }

  if ($form->{id}) {

    my $i = 0;

    foreach my $ref (@{ $form->{invoice_details} }) {
      $i++;

      map { $form->{"${_}_$i"} = $ref->{$_} } keys %{$ref};

      $form->{"discount_$i"}   = $form->format_amount(\%myconfig, $form->{"discount_$i"} * 100);
      my ($dec)                = ($form->{"sellprice_$i"} =~ /\.(\d+)/);
      $dec                     = length $dec;
      my $decimalplaces        = ($dec > 2) ? $dec : 2;

      $form->{"sellprice_$i"}  = $form->format_amount(\%myconfig, $form->{"sellprice_$i"}, $decimalplaces);
      (my $dec_qty)            = ($form->{"qty_$i"} =~ /\.(\d+)/);
      $dec_qty                 = length $dec_qty;

      $form->{"qty_$i"}        = $form->format_amount(\%myconfig, $form->{"qty_$i"}, $dec_qty);

      $form->{rowcount}        = $i;

    }

    # get pricegroups for parts
    IS->get_pricegroups_for_parts(\%myconfig, \%$form);
    set_pricegroup($_) for 1 .. $form->{rowcount};
  }
  $main::lxdebug->leave_sub();
}

sub form_header {
  $main::lxdebug->enter_sub();

  my $form     = $main::form;
  my %myconfig = %main::myconfig;
  my $locale   = $main::locale;
  my $cgi      = $main::cgi;

  $main::auth->assert('invoice_edit');

  our %TMPL_VAR = ();
  my @custom_hiddens;

  $form->{employee_id} = $form->{old_employee_id} if $form->{old_employee_id};
  $form->{salesman_id} = $form->{old_salesman_id} if $form->{old_salesman_id};

  $form->{defaultcurrency} = $form->get_default_currency(\%myconfig);
  $form->{radier}          = ($form->current_date(\%myconfig) eq $form->{gldate}) ? 1 : 0;

  $payment = qq|<option value=""></option>|;
  foreach my $item (@{ $form->{payment_terms} }) {
    if ($form->{payment_id} eq $item->{id}) {
      $payment .= qq|<option value="$item->{id}" selected>$item->{description}</option>|;
    } else {
      $payment .= qq|<option value="$item->{id}">$item->{description}</option>|;
    }
  }

  my $set_duedate_url = "$form->{script}?action=set_duedate";

  push @ { $form->{AJAX} }, new CGI::Ajax( 'set_duedate' => $set_duedate_url );

  my @old_project_ids = ($form->{"globalproject_id"});
  map { push @old_project_ids, $form->{"project_id_$_"} if $form->{"project_id_$_"}; } 1..$form->{"rowcount"};

  $form->get_lists("contacts"      => "ALL_CONTACTS",
                   "shipto"        => "ALL_SHIPTO",
                   "projects"      => { "key"    => "ALL_PROJECTS",
                                        "all"    => 0,
                                        "old_id" => \@old_project_ids },
                   "employees"     => "ALL_EMPLOYEES",
                   "salesmen"      => "ALL_SALESMEN",
                   "taxzones"      => "ALL_TAXZONES",
                   "currencies"    => "ALL_CURRENCIES",
                   "customers"     => "ALL_CUSTOMERS",
                   "price_factors" => "ALL_PRICE_FACTORS");

  $TMPL_VAR{sales_employee_labels} = sub { $_[0]->{name} || $_[0]->{login} };
  $TMPL_VAR{shipto_labels}         = sub { join "; ", grep { $_ } map { $_[0]->{"shipto${_}" } } qw(name department_1 street city) };
  $TMPL_VAR{contact_labels}        = sub { join(', ', $_[0]->{"cp_name"}, $_[0]->{"cp_givenname"}) . ($_[0]->{cp_abteilung} ? " ($_[0]->{cp_abteilung})" : "") };
  $TMPL_VAR{department_labels}     = sub { "$_[0]->{description}--$_[0]->{id}" };

  # customer
  $TMPL_VAR{vc_keys} = sub { "$_[0]->{name}--$_[0]->{id}" };
  $TMPL_VAR{vclimit} = $myconfig{vclimit};
  $TMPL_VAR{vc_select} = "customer_or_vendor_selection_window('customer', '', 0, 0)";
  push @custom_hiddens, "customer_id";
  push @custom_hiddens, "oldcustomer";
  push @custom_hiddens, "selectcustomer";

  # currencies and exchangerate
  my @values = map { $_       } @{ $form->{ALL_CURRENCIES} };
  my %labels = map { $_ => $_ } @{ $form->{ALL_CURRENCIES} };
  $form->{currency}            = $form->{defaultcurrency} unless $form->{currency};
  $TMPL_VAR{show_exchangerate} = $form->{currency} ne $form->{defaultcurrency};
  $TMPL_VAR{currencies}        = NTI($cgi->popup_menu('-name' => 'currency', '-default' => $form->{"currency"},
                                                      '-values' => \@values, '-labels' => \%labels)) if scalar @values;
  push @custom_hiddens, "forex";
  push @custom_hiddens, "exchangerate" if $form->{forex};

  $TMPL_VAR{creditwarning} = ($form->{creditlimit} != 0) && ($form->{creditremaining} < 0) && !$form->{update};
  $TMPL_VAR{is_credit_remaining_negativ} = $form->{creditremaining} =~ /-/;

  $form->{fokus} = "invoice.customer";

  my $follow_up_vc         =  $form->{customer};
  $follow_up_vc            =~ s/--\d*\s*$//;
  $TMPL_VAR{customer_name} = $follow_up_vc;

# set option selected
  foreach my $item (qw(AR)) {
    $form->{"select$item"} =~ s/ selected//;
    $form->{"select$item"} =~ s/option>\Q$form->{$item}\E/option selected>$form->{$item}/;
  }

  $TMPL_VAR{is_type_credit_note} = $form->{type}   eq "credit_note";
  $TMPL_VAR{is_format_html}      = $form->{format} eq 'html';
  $TMPL_VAR{dateformat}          = $myconfig{dateformat};
  $TMPL_VAR{numberformat}        = $myconfig{numberformat};

  # hiddens
  $TMPL_VAR{HIDDENS} = [qw(
    id action type media format queued printed emailed title vc discount
    title creditlimit creditremaining tradediscount business closedto locked shipped storno storno_id
    max_dunning_level dunning_amount
    shiptoname shiptostreet shiptozipcode shiptocity shiptocountry  shiptocontact shiptophone shiptofax
    shiptoemail shiptodepartment_1 shiptodepartment_2 message email subject cc bcc taxaccounts cursor_fokus
    convert_from_do_ids convert_from_oe_ids
  ), @custom_hiddens,
  map { $_.'_rate', $_.'_description', $_.'_taxnumber' } split / /, $form->{taxaccounts}];

  $form->{jsscript} = 1;
  $form->header();

  print $form->parse_html_template("is/form_header", \%TMPL_VAR);

  $main::lxdebug->leave_sub();
}

sub form_footer {
  $main::lxdebug->enter_sub();

  my $form     = $main::form;
  my %myconfig = %main::myconfig;
  my $locale   = $main::locale;
  my $cgi      = $main::cgi;

  $main::auth->assert('invoice_edit');

  $form->{invtotal} = $form->{invsubtotal};

  my ($rows, $introws);
  if (($rows    = $form->numtextrows($form->{notes}, 26, 8)) < 2)    { $rows    = 2; }
  if (($introws = $form->numtextrows($form->{intnotes}, 35, 8)) < 2) { $introws = 2; }
  $form->{rows} = ($rows > $introws) ? $rows : $introws;

  my ($tax, $subtotal);
  $form->{taxaccounts_array} = [ split / /, $form->{taxaccounts} ];

  foreach my $item (@{ $form->{taxaccounts_array} }) {
    if ($form->{"${item}_base"}) {
      if ($form->{taxincluded}) {
        $form->{"${item}_total"} = $form->round_amount( ($form->{"${item}_base"} * $form->{"${item}_rate"}
                                                                                 / (1 + $form->{"${item}_rate"})), 2);
        $form->{"${item}_netto"} = $form->round_amount( ($form->{"${item}_base"} - $form->{"${item}_total"}), 2);
      } else {
        $form->{"${item}_total"} = $form->round_amount( $form->{"${item}_base"} * $form->{"${item}_rate"}, 2);
        $form->{invtotal} += $form->{"${item}_total"};
      }
    }
  }

  $form->{oldinvtotal} = $form->{invtotal};

  # unfortunately locales doesn't support extended syntax
  if ($form->{id}) {
    my $follow_ups = FU->follow_ups('trans_id' => $form->{id});
    if (@{ $follow_ups} ) {
      $form->{follow_up_text} = $locale->text("There are #1 unfinished follow-ups of which #2 are due.",
                                               scalar(@{ $follow_ups }),
                                               sum map { $_->{due} * 1 } @{ $follow_ups });
    }
  }


# payments
  my $totalpaid = 0;

  $form->{paidaccounts}++ if ($form->{"paid_$form->{paidaccounts}"});
  $form->{paid_indices} = [ 1 .. $form->{paidaccounts} ];

  for my $i (1 .. $form->{paidaccounts}) {
    $form->{"selectAR_paid_$i"} = $form->{selectAR_paid};
    $form->{"selectAR_paid_$i"} =~ s/option>\Q$form->{"AR_paid_$i"}\E/option selected>$form->{"AR_paid_$i"}/;

    # format amounts
    $totalpaid += $form->{"paid_$i"};
  }

  $form->{print_options} = print_options(inline => 1);

  print $form->parse_html_template('is/form_footer');
# print $form->parse_html_template('is/_payments'); # parser



#  print qq|
#  <tr>
#    <td>
#      <table width="100%">
#	<tr valign="bottom">
#	  <td>
#	    <table>
#	      <tr>
#		<th align="left">| . $locale->text('Notes') . qq|</th>
#		<th align="left">| . $locale->text('Internal Notes') . qq|</th>
#                <th align="right">| . $locale->text('Payment Terms') . qq|</th>
#	      </tr>
#	      <tr valign="top">
#		<td>$notes</td>
#		<td>$intnotes</td>
#                <td><select name="payment_id" onChange="if (this.value) set_duedate(['payment_id__' + this.value, 'invdate__' + invdate.value],['duedate'])">$payment
#                </select></td>
#	      </tr>
#        $follow_ups_block
#	    </table>
#	  </td>
#          <td>
#            <table>
#            <tr>
#              <th  align=left>| . $locale->text('Ertrag') . qq|</th>
#              <td>| .  $form->format_amount(\%myconfig, $form->{marge_total}, 2, 0) . qq|</td>
#            </tr>
#            <tr>
#              <th  align=left>| . $locale->text('Ertrag prozentual') . qq|</th>
#              <td>| .  $form->format_amount(\%myconfig, $form->{marge_percent}, 2, 0) . qq| %</td>
#            </tr>
#            <input type=hidden name="marge_total" value="$form->{"marge_total"}">
#            <input type=hidden name="marge_percent" value="$form->{"marge_percent"}">
#            </table>
#          </td>
#	  <td align="right">
#	    $taxincluded
#	    <table>
#	      $subtotal
#	      $tax
#	      <tr>
#		<th align="right">| . $locale->text('Total') . qq|</th>
#		<td align="right">$form->{invtotal}</td>
#	      </tr>
#	    </table>
#	  </td>
#	</tr>
#      </table>
#    </td>
#  </tr>
#|;
#  my $webdav_list;
#  if ($main::webdav) {
#    $webdav_list = qq|
#  <tr>
#    <td><hr size="3" noshade></td>
#  </tr>
#  <tr>
#    <th class="listtop" align="left">Dokumente im Webdav-Repository</th>
#  </tr>
#    <table width="100%">
#      <td align="left" width="30%"><b>Dateiname</b></td>
#      <td align="left" width="70%"><b>Webdavlink</b></td>
#|;
#    foreach my $file (@{ $form->{WEBDAV} }) {
#      $webdav_list .= qq|
#      <tr>
#        <td align="left">$file->{name}</td>
#        <td align="left"><a href="$file->{link}">$file->{type}</a></td>
#      </tr>
#|;
#    }
#    $webdav_list .= qq|
#    </table>
#  </tr>
#|;
#
#    print $webdav_list;
#  }
#if ($form->{type} eq "credit_note") {
#  print qq|
#  <tr>
#    <td>
#      <table width="100%">
#	<tr class="listheading">
#	  <th colspan="6" class="listheading">|
#    . $locale->text('Payments') . qq|</th>
#	</tr>
#|;
#} else {
#  print qq|
#  <tr>
#    <td>
#      <table width="100%">
#	<tr class="listheading">
#	  <th colspan="6" class="listheading">|
#    . $locale->text('Incoming Payments') . qq|</th>
#	</tr>
#|;
#}
#
#  my @column_index;
#  if ($form->{currency} eq $form->{defaultcurrency}) {
#    @column_index = qw(datepaid source memo paid AR_paid);
#  } else {
#    @column_index = qw(datepaid source memo paid exchangerate AR_paid);
#  }
#
#  my %column_data;
#  $column_data{datepaid}     = "<th>" . $locale->text('Date') . "</th>";
#  $column_data{paid}         = "<th>" . $locale->text('Amount') . "</th>";
#  $column_data{exchangerate} = "<th>" . $locale->text('Exch') . "</th>";
#  $column_data{AR_paid}      = "<th>" . $locale->text('Account') . "</th>";
#  $column_data{source}       = "<th>" . $locale->text('Source') . "</th>";
#  $column_data{memo}         = "<th>" . $locale->text('Memo') . "</th>";
#
#  print "
#	<tr>
#";
#  map { print "$column_data{$_}\n" } @column_index;
#  print "
#        </tr>
#";
#
#  my @triggers  = ();
#  my $totalpaid = 0;
#
#  $form->{paidaccounts}++ if ($form->{"paid_$form->{paidaccounts}"});
#  for my $i (1 .. $form->{paidaccounts}) {
#
#    print "
#        <tr>\n";
#
#    $form->{"selectAR_paid_$i"} = $form->{selectAR_paid};
#    $form->{"selectAR_paid_$i"} =~
#      s/option>\Q$form->{"AR_paid_$i"}\E/option selected>$form->{"AR_paid_$i"}/;
#
#    # format amounts
#    $totalpaid += $form->{"paid_$i"};
#    if ($form->{"paid_$i"}) {
#      $form->{"paid_$i"} = $form->format_amount(\%myconfig, $form->{"paid_$i"}, 2);
#    }
#    $form->{"exchangerate_$i"} = $form->format_amount(\%myconfig, $form->{"exchangerate_$i"});
#
#    if ($form->{"exchangerate_$i"} == 0) {
#      $form->{"exchangerate_$i"} = "";
#    }
#    my $exchangerate = qq|&nbsp;|;
#    if ($form->{currency} ne $form->{defaultcurrency}) {
#      if ($form->{"forex_$i"}) {
#        $exchangerate = qq|<input type="hidden" name="exchangerate_$i" value="$form->{"exchangerate_$i"}">$form->{"exchangerate_$i"}|;
#      } else {
#        $exchangerate = qq|<input name="exchangerate_$i" size="10" value="$form->{"exchangerate_$i"}">|;
#      }
#    }
#
#    $exchangerate .= qq|<input type="hidden" name="forex_$i" value="$form->{"forex_$i"}">|;
#
#    $column_data{"paid_$i"} =
#      qq|<td align="center"><input name="paid_$i" size="11" value="$form->{"paid_$i"}" onBlur=\"check_right_number_format(this)\"></td>|;
#    $column_data{"exchangerate_$i"} = qq|<td align="center">$exchangerate</td>|;
#    $column_data{"AR_paid_$i"}      =
#      qq|<td align="center"><select name="AR_paid_$i">$form->{"selectAR_paid_$i"}</select></td>|;
#    $column_data{"datepaid_$i"} =
#      qq|<td align="center"><input id="datepaid_$i" name="datepaid_$i"  size="11" title="$myconfig{dateformat}" value="$form->{"datepaid_$i"}" onBlur=\"check_right_date_format(this)\">
#         <input type="button" name="datepaid_$i" id="trigger_datepaid_$i" value="?"></td>|;
#    $column_data{"source_$i"} =
#      qq|<td align=center><input name="source_$i" size="11" value="$form->{"source_$i"}"></td>|;
#    $column_data{"memo_$i"} =
#      qq|<td align="center"><input name="memo_$i" size="11" value="$form->{"memo_$i"}"></td>|;
#
#    map { print qq|$column_data{"${_}_$i"}\n| } @column_index;
#    print "
#        </tr>\n";
#    push(@triggers, "datepaid_$i", "BL", "trigger_datepaid_$i");
#  }
#
#  my $paid_missing = $form->{oldinvtotal} - $totalpaid;
#
#  print qq|
#    <tr>
#      <td></td>
#      <td></td>
#      <td align="center">| . $locale->text('Total') . qq|</td>
#      <td align="center">| . H($form->format_amount(\%myconfig, $totalpaid, 2)) . qq|</td>
#    </tr>
#    <tr>
#      <td></td>
#      <td></td>
#      <td align="center">| . $locale->text('Missing amount') . qq|</td>
#      <td align="center">| . H($form->format_amount(\%myconfig, $paid_missing, 2)) . qq|</td>
#    </tr>
#|;
#
#  map({ print($cgi->hidden("-name" => $_, "-value" => $form->{$_})); } qw(paidaccounts selectAR_paid oldinvtotal));
#  print qq|<input type="hidden" name="oldtotalpaid" value="$totalpaid">
#    </table>
#    </td>
#  </tr>
#  <tr>
#    <td><hr size="3" noshade></td>
#  </tr>
#  <tr>
#    <td>
#|;
#
#  print_options();
#
#  print qq|
#    </td>
#  </tr>
#</table>
#|;
#
#  my $invdate  = $form->datetonum($form->{invdate},  \%myconfig);
#  my $closedto = $form->datetonum($form->{closedto}, \%myconfig);
#
#  if ($form->{id}) {
#    my $show_storno = !$form->{storno} && !IS->has_storno(\%myconfig, $form, "ar") && (($totalpaid == 0) || ($totalpaid eq ""));
#
#    print qq|
#    <input class="submit" type="submit" accesskey="u" name="action" id="update_button" value="| . $locale->text('Update') . qq|">
#    <input class="submit" type="submit" name="action" value="| . $locale->text('Ship to') . qq|">
#    <input class="submit" type="submit" name="action" value="| . $locale->text('Print') . qq|">
#    <input class="submit" type="submit" name="action" value="| . $locale->text('E-mail') . qq|"> |;
#    print qq|<input class="submit" type="submit" name="action" value="| . $locale->text('Storno') . qq|"> | if ($show_storno);
#    print qq|<input class="submit" type="submit" name="action" value="| . $locale->text('Post Payment') . qq|"> |;
#    print qq|<input class="submit" type="submit" name="action" value="| . $locale->text('Use As Template') . qq|"> |;
#    if ($form->{id} && !($form->{type} eq "credit_note")) {
#      print qq| <input class="submit" type="submit" name="action" value="| . $locale->text('Credit Note') . qq|"> |;
#    }
#    if ($form->{radier}) {
#      print qq| <input class="submit" type="submit" name="action" value="| . $locale->text('Delete') . qq|"> |;
#    }
#
#
#    if ($invdate > $closedto) {
#      print qq| <input class="submit" type="submit" name="action" value="| . $locale->text('Order') . qq|"> |;
#    }
#
#    print qq| <input type="button" class="submit" onclick="follow_up_window()" value="| . $locale->text('Follow-Up') . qq|">|;
#
#  } else {
#    if ($invdate > $closedto) {
#      print qq|
#      <input class="submit" type="submit" name="action" id="update_button" value="| . $locale->text('Update') . qq|">
#      <input class="submit" type="submit" name="action" value="| . $locale->text('Ship to') . qq|">
#      <input class="submit" type="submit" name="action" value="| . $locale->text('Preview') . qq|">
#      <input class="submit" type="submit" name="action" value="| . $locale->text('E-mail') . qq|">
#      <input class="submit" type="submit" name="action" value="| . $locale->text('Print and Post') . qq|">
#      <input class="submit" type="submit" name="action" value="| . $locale->text('Post') . qq|"> | .
#        NTI($cgi->submit('-name' => 'action', '-value' => $locale->text('Save draft'), '-class' => 'submit'));
#    }
#  }
#
#  # button for saving history
#  if($form->{id} ne "") {
#    print qq|
#  	  <input type="button" class="submit" onclick="set_history_window(|
#  	  . Q($form->{id})
#  	  . qq|);" name="history" id="history" value="|
#  	  . $locale->text('history')
#  	  . qq|"> |;
#  }
#  # /button for saving history
#
#  # mark_as_paid button
#  if($form->{id} ne "") {
#    print qq|<input type="submit" class="submit" name="action" value="| . $locale->text('mark as paid') . qq|">|;
#  }
#  # /mark_as_paid button
#  print $form->write_trigger(\%myconfig, scalar(@triggers) / 3, @triggers) .
#    qq|
#
#<input type="hidden" name="rowcount" value="$form->{rowcount}">
#| .
#$cgi->hidden("-name" => "callback", "-value" => $form->{callback})
#. $cgi->hidden('-name' => 'draft_id', '-default' => [$form->{draft_id}])
#. $cgi->hidden('-name' => 'draft_description', '-default' => [$form->{draft_description}])
#. $cgi->hidden('-name' => 'customer_discount', '-value' => [$form->{customer_discount}])
#. qq|
#</form>
#
#</body>
#
# </html>
#|;

  $main::lxdebug->leave_sub();
}

sub mark_as_paid {
  $main::lxdebug->enter_sub();

  my $form     = $main::form;
  my %myconfig = %main::myconfig;

  $main::auth->assert('invoice_edit');

  &mark_as_paid_common(\%myconfig,"ar");

  $main::lxdebug->leave_sub();
}

sub update {
  $main::lxdebug->enter_sub();

  my $form     = $main::form;
  my %myconfig = %main::myconfig;

  $main::auth->assert('invoice_edit');

  my ($recursive_call) = shift;

  map { $form->{$_} = $form->parse_amount(\%myconfig, $form->{$_}) } qw(exchangerate creditlimit creditremaining) unless $recursive_call;

  $form->{print_and_post} = 0         if $form->{second_run};
  my $taxincluded            = "checked" if $form->{taxincluded};
  $form->{update} = 1;

  &check_name("customer");

  $form->{taxincluded} ||= $taxincluded;

  $form->{forex}        = $form->check_exchangerate(\%myconfig, $form->{currency}, $form->{invdate}, 'buy');
  $form->{exchangerate} = $form->{forex} if $form->{forex};

  for my $i (1 .. $form->{paidaccounts}) {
    next unless $form->{"paid_$i"};
    map { $form->{"${_}_$i"} = $form->parse_amount(\%myconfig, $form->{"${_}_$i"}) } qw(paid exchangerate);
    $form->{"forex_$i"}        = $form->check_exchangerate(\%myconfig, $form->{currency}, $form->{"datepaid_$i"}, 'buy');
    $form->{"exchangerate_$i"} = $form->{"forex_$i"} if $form->{"forex_$i"};
  }

  my $i            = $form->{rowcount};
  my $exchangerate = $form->{exchangerate} || 1;

  # if last row empty, check the form otherwise retrieve new item
  if (   ($form->{"partnumber_$i"} eq "")
      && ($form->{"description_$i"} eq "")
      && ($form->{"partsgroup_$i"}  eq "")) {

    $form->{creditremaining} += ($form->{oldinvtotal} - $form->{oldtotalpaid});
    &check_form;

  } else {

    IS->retrieve_item(\%myconfig, \%$form);

    my $rows = scalar @{ $form->{item_list} };

    $form->{"discount_$i"} = $form->format_amount(\%myconfig, $form->{customer_discount} * 100);

    if ($rows) {
      $form->{"qty_$i"} = ($form->{"qty_$i"} * 1) ? $form->{"qty_$i"} : 1;

      if ($rows > 1) {

        &select_item;
        exit;

      } else {

        my $sellprice = $form->parse_amount(\%myconfig, $form->{"sellprice_$i"});

        map { $form->{item_list}[$i]{$_} =~ s/\"/&quot;/g } qw(partnumber description unit);
        map { $form->{"${_}_$i"} = $form->{item_list}[0]{$_} } keys %{ $form->{item_list}[0] };

        $form->{payment_id}    = $form->{"part_payment_id_$i"} if $form->{"part_payment_id_$i"} ne "";
        $form->{"discount_$i"} = 0                             if $form->{"not_discountable_$i"};

        $form->{"marge_price_factor_$i"} = $form->{item_list}->[0]->{price_factor};

        ($sellprice || $form->{"sellprice_$i"}) =~ /\.(\d+)/;
        my $decimalplaces = max 2, length $1;

        if ($sellprice) {
          $form->{"sellprice_$i"} = $sellprice;
        } else {
          # if there is an exchange rate adjust sellprice
          $form->{"sellprice_$i"} *= (1 - $form->{tradediscount});
          $form->{"sellprice_$i"} /= $exchangerate;
        }

        $form->{"listprice_$i"} /= $exchangerate;

        my $amount = $form->{"sellprice_$i"} * $form->{"qty_$i"} * (1 - $form->{"discount_$i"} / 100);
        map { $form->{"${_}_base"} = 0 }                                 split / /, $form->{taxaccounts};
        map { $form->{"${_}_base"} += $amount }                          split / /, $form->{"taxaccounts_$i"};
        map { $amount += ($form->{"${_}_base"} * $form->{"${_}_rate"}) } split / /, $form->{"taxaccounts_$i"} if !$form->{taxincluded};

        $form->{creditremaining} -= $amount;

        map { $form->{"${_}_$i"} = $form->format_amount(\%myconfig, $form->{"${_}_$i"}, $decimalplaces) } qw(sellprice listprice);

        $form->{"qty_$i"} = $form->format_amount(\%myconfig, $form->{"qty_$i"});

        if ($main::lizenzen) {
          if ($form->{"inventory_accno_$i"} ne "") {
            $form->{"lizenzen_$i"} = qq|<option></option>|;
            foreach my $item (@{ $form->{LIZENZEN}{ $form->{"id_$i"} } }) {
              $form->{"lizenzen_$i"} .= qq|<option value="$item->{"id"}">$item->{"licensenumber"}</option>|;
            }
            $form->{"lizenzen_$i"} .= qq|<option value=-1>Neue Lizenz</option>|;
          }
        }

        # get pricegroups for parts
        IS->get_pricegroups_for_parts(\%myconfig, \%$form);

        # build up html code for prices_$i
        &set_pricegroup($i);
      }

      &display_form;

    } else {

      # ok, so this is a new part
      # ask if it is a part or service item

      if (   $form->{"partsgroup_$i"}
          && ($form->{"partsnumber_$i"} eq "")
          && ($form->{"description_$i"} eq "")) {
        $form->{rowcount}--;
        $form->{"discount_$i"} = "";
        display_form();

      } else {
        $form->{"id_$i"}   = 0;
        new_item();
      }
    }
  }
  $main::lxdebug->leave_sub();
}

sub post_payment {
  $main::lxdebug->enter_sub();

  my $form     = $main::form;
  my %myconfig = %main::myconfig;
  my $locale   = $main::locale;

  $main::auth->assert('invoice_edit');

  our $invdate;

  $form->{defaultcurrency} = $form->get_default_currency(\%myconfig);
  for my $i (1 .. $form->{paidaccounts}) {
    if ($form->{"paid_$i"}) {
      my $datepaid = $form->datetonum($form->{"datepaid_$i"}, \%myconfig);

      $form->isblank("datepaid_$i", $locale->text('Payment date missing!'));

      $form->error($locale->text('Cannot post payment for a closed period!'))
        if ($form->date_closed($form->{"datepaid_$i"}, \%myconfig));

      if ($form->{currency} ne $form->{defaultcurrency}) {
        $form->{"exchangerate_$i"} = $form->{exchangerate}
          if ($invdate == $datepaid);
        $form->isblank("exchangerate_$i",
                       $locale->text('Exchangerate for payment missing!'));
      }
    }
  }

  ($form->{AR})      = split /--/, $form->{AR};
  ($form->{AR_paid}) = split /--/, $form->{AR_paid};
  relink_accounts();
  $form->redirect($locale->text('Payment posted!'))
      if (IS->post_payment(\%myconfig, \%$form));
    $form->error($locale->text('Cannot post payment!'));


  $main::lxdebug->leave_sub();
}

sub post {
  $main::lxdebug->enter_sub();

  my $form     = $main::form;
  my %myconfig = %main::myconfig;
  my $locale   = $main::locale;

  $main::auth->assert('invoice_edit');

  $form->{defaultcurrency} = $form->get_default_currency(\%myconfig);
  $form->isblank("invdate",  $locale->text('Invoice Date missing!'));
  $form->isblank("customer", $locale->text('Customer missing!'));
  $form->error($locale->text('Cannot post invoice for a closed period!'))
        if ($form->date_closed($form->{"invdate"}, \%myconfig));

  $form->{invnumber} =~ s/^\s*//g;
  $form->{invnumber} =~ s/\s*$//g;

  # if oldcustomer ne customer redo form
  if (&check_name('customer')) {
    &update;
    exit;
  }
  if ($form->{second_run}) {
    $form->{print_and_post} = 0;
  }

  &validate_items;

  my $closedto = $form->datetonum($form->{closedto}, \%myconfig);
  my $invdate  = $form->datetonum($form->{invdate},  \%myconfig);

  $form->error($locale->text('Cannot post invoice for a closed period!'))
    if ($invdate <= $closedto);

  $form->isblank("exchangerate", $locale->text('Exchangerate missing!'))
    if ($form->{currency} ne $form->{defaultcurrency});

  for my $i (1 .. $form->{paidaccounts}) {
    if ($form->parse_amount(\%myconfig, $form->{"paid_$i"})) {
      my $datepaid = $form->datetonum($form->{"datepaid_$i"}, \%myconfig);

      $form->isblank("datepaid_$i", $locale->text('Payment date missing!'));

      $form->error($locale->text('Cannot post payment for a closed period!'))
        if ($form->date_closed($form->{"datepaid_$i"}, \%myconfig));

      if ($form->{currency} ne $form->{defaultcurrency}) {
        $form->{"exchangerate_$i"} = $form->{exchangerate}
          if ($invdate == $datepaid);
        $form->isblank("exchangerate_$i",
                       $locale->text('Exchangerate for payment missing!'));
      }
    }
  }

  ($form->{AR})        = split /--/, $form->{AR};
  ($form->{AR_paid})   = split /--/, $form->{AR_paid};
  $form->{storno}    ||= 0;

  $form->{label} = $locale->text('Invoice');

  $form->{id} = 0 if $form->{postasnew};

  # get new invnumber in sequence if no invnumber is given or if posasnew was requested
  if ($form->{postasnew}) {
    if ($form->{type} eq "credit_note") {
      undef($form->{cnnumber});
    } else {
      undef($form->{invnumber});
    }
  }

  relink_accounts();
  $form->error($locale->text('Cannot post invoice!'))
    unless IS->post_invoice(\%myconfig, \%$form);
  remove_draft() if $form->{remove_draft};

  if(!exists $form->{addition}) {
    $form->{snumbers} = qq|invnumber_| . $form->{invnumber};
    $form->{addition} = $print_post     ? "PRINTED AND POSTED" :
                        $form->{storno} ? "STORNO"             :
                                          "POSTED";
    $form->save_history($form->dbconnect(\%myconfig));
  }

  $form->redirect( $form->{label} . " $form->{invnumber} " . $locale->text('posted!'))
    unless $print_post;

  $main::lxdebug->leave_sub();
}

sub print_and_post {
  $main::lxdebug->enter_sub();

  my $form     = $main::form;

  $main::auth->assert('invoice_edit');

  my $old_form               = new Form;
  $print_post             = 1;
  $form->{print_and_post} = 1;
  &post();

  &edit();
  $main::lxdebug->leave_sub();

}

sub use_as_template {
  $main::lxdebug->enter_sub();

  my $form     = $main::form;
  my %myconfig = %main::myconfig;

  $main::auth->assert('invoice_edit');

  map { delete $form->{$_} } qw(printed emailed queued invnumber invdate deliverydate id datepaid_1 source_1 memo_1 paid_1 exchangerate_1 AP_paid_1 storno);
  $form->{paidaccounts} = 1;
  $form->{rowcount}--;
  $form->{invdate} = $form->current_date(\%myconfig);
  &display_form;

  $main::lxdebug->leave_sub();
}

sub storno {
  $main::lxdebug->enter_sub();

  my $form     = $main::form;
  my %myconfig = %main::myconfig;
  my $locale   = $main::locale;

  $main::auth->assert('invoice_edit');

  if ($form->{storno}) {
    $form->error($locale->text('Cannot storno storno invoice!'));
  }

  if (IS->has_storno(\%myconfig, $form, "ar")) {
    $form->error($locale->text("Invoice has already been storno'd!"));
  }

  map({ my $key = $_; delete($form->{$key}) unless (grep({ $key eq $_ } qw(id login password stylesheet type))); } keys(%{ $form }));

  invoice_links();
  prepare_invoice();
  relink_accounts();

  # Payments must not be recorded for the new storno invoice.
  $form->{paidaccounts} = 0;
  map { my $key = $_; delete $form->{$key} if grep { $key =~ /^$_/ } qw(datepaid_ source_ memo_ paid_ exchangerate_ AR_paid_) } keys %{ $form };

  $form->{storno_id} = $form->{id};
  $form->{storno} = 1;
  $form->{id} = "";
  $form->{invnumber} = "Storno zu " . $form->{invnumber};
  $form->{rowcount}++;

  post();
  $main::lxdebug->leave_sub();
}

sub preview {
  $main::lxdebug->enter_sub();

  my $form     = $main::form;

  $main::auth->assert('invoice_edit');

  $form->{preview} = 1;
  my $old_form = new Form;
  for (keys %$form) { $old_form->{$_} = $form->{$_} }

  &print_form($old_form);
  $main::lxdebug->leave_sub();

}

sub delete {
  $main::lxdebug->enter_sub();

  my $form     = $main::form;
  my $locale   = $main::locale;

  $main::auth->assert('invoice_edit');

  if ($form->{second_run}) {
    $form->{print_and_post} = 0;
  }
  $form->header;

  print qq|
<body>

<form method="post" action="$form->{script}">
|;

  # delete action variable
  map { delete $form->{$_} } qw(action header);

  foreach my $key (keys %$form) {
    next if (($key eq 'login') || ($key eq 'password') || ('' ne ref $form->{$key}));
    $form->{$key} =~ s/\"/&quot;/g;
    print qq|<input type="hidden" name="$key" value="$form->{$key}">\n|;
  }

  print qq|
<h2 class="confirm">| . $locale->text('Confirm!') . qq|</h2>

<h4>|
    . $locale->text('Are you sure you want to delete Invoice Number')
    . qq| $form->{invnumber}
</h4>

<p>
<input name="action" class="submit" type="submit" value="|
    . $locale->text('Yes') . qq|">
</form>
|;

  $main::lxdebug->leave_sub();
}

sub credit_note {
  $main::lxdebug->enter_sub();

  my $form     = $main::form;
  my %myconfig = %main::myconfig;
  my $locale   = $main::locale;

  $main::auth->assert('invoice_edit');

  $form->{transdate} = $form->{invdate} = $form->current_date(\%myconfig);
  $form->{duedate} =
    $form->current_date(\%myconfig, $form->{invdate}, $form->{terms} * 1);

  $form->{id}     = '';
  $form->{rowcount}--;
  $form->{shipto} = 1;


  $form->{title}  = $locale->text('Add Credit Note');
  $form->{script} = 'is.pl';
  our $script         = "is";
  our $buysell        = 'buy';


  # bo creates the id, reset it
  map { delete $form->{$_} }
    qw(id invnumber subject message cc bcc printed emailed queued);
  $form->{ $form->{vc} } =~ s/--.*//g;
  $form->{type} = "credit_note";


  map { $form->{"select$_"} = "" } ($form->{vc}, 'currency');

  map { $form->{$_} = $form->parse_amount(\%myconfig, $form->{$_}) }
    qw(creditlimit creditremaining);

  my $currency = $form->{currency};
  &invoice_links;

  $form->{currency}     = $currency;
  $form->{forex}        = $form->check_exchangerate( \%myconfig, $form->{currency}, $form->{invdate}, $buysell);
  $form->{exchangerate} = $form->{forex} || '';

  $form->{creditremaining} -= ($form->{oldinvtotal} - $form->{ordtotal});

  &prepare_invoice;


  &display_form;

  $main::lxdebug->leave_sub();
}

sub yes {
  $main::lxdebug->enter_sub();

  my $form     = $main::form;
  my %myconfig = %main::myconfig;
  my $locale   = $main::locale;

  $main::auth->assert('invoice_edit');

  if (IS->delete_invoice(\%myconfig, \%$form, $main::spool)) {
    # saving the history
  	if(!exists $form->{addition}) {
    $form->{snumbers} = qq|invnumber_| . $form->{invnumber};
  	  $form->{addition} = "DELETED";
  	  $form->save_history($form->dbconnect(\%myconfig));
    }
    # /saving the history
    $form->redirect($locale->text('Invoice deleted!'));
  }
  $form->error($locale->text('Cannot delete invoice!'));

  $main::lxdebug->leave_sub();
}

sub e_mail {
  $main::lxdebug->enter_sub();

  my $form     = $main::form;

  $main::auth->assert('invoice_edit');

  if (!$form->{id}) {
    $print_post = 1;

    my $saved_form = save_form();

    post();

    restore_form($saved_form, 0, qw(id invnumber));
  }

  edit_e_mail();

  $main::lxdebug->leave_sub();
}
