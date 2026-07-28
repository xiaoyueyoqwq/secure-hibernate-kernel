#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-2.0-only

use strict;
use warnings;

die "Usage: extract-module-signature.pl MODULE CONTENT_OUTPUT SIGNATURE_OUTPUT\n"
	if @ARGV != 3;

my ($module_path, $content_path, $signature_path) = @ARGV;
my $magic = "~Module signature appended~\n";

open my $module_file, '<:raw', $module_path or die "$module_path: $!\n";
local $/;
my $module = <$module_file>;
close $module_file or die "$module_path: $!\n";

my $minimum_length = length($magic) + 12;
die "$module_path: too short to contain a module signature\n"
	if length($module) < $minimum_length;
die "$module_path: module signature marker is missing\n"
	if substr($module, -length($magic)) ne $magic;

my $descriptor_offset = length($module) - length($magic) - 12;
my ($algorithm, $hash, $identifier_type, $signer_length, $key_id_length,
	$signature_length) = unpack('CCCCCxxxN', substr($module, $descriptor_offset, 12));

die "$module_path: expected a PKCS#7 module signature\n"
	if $identifier_type != 2;
die "$module_path: unexpected PKCS#7 descriptor values\n"
	if $algorithm != 0 || $hash != 0 || $signer_length != 0 || $key_id_length != 0;
die "$module_path: empty or truncated module signature\n"
	if $signature_length == 0 || $signature_length > $descriptor_offset;

my $content_length = $descriptor_offset - $signature_length;
my $signature = substr($module, $content_length, $signature_length);

open my $content_file, '>:raw', $content_path or die "$content_path: $!\n";
print {$content_file} substr($module, 0, $content_length);
close $content_file or die "$content_path: $!\n";

open my $signature_file, '>:raw', $signature_path or die "$signature_path: $!\n";
print {$signature_file} $signature;
close $signature_file or die "$signature_path: $!\n";
