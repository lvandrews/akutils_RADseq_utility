#!/usr/bin/env bash
#
#  config_id.sh - determine akutils config file to use - modified for RADseq
#
#  Version 1.0.0 (April, 18, 2016)
#
#  Copyright (c) 2015-2016 Andrew Krohn
#
#  This software is provided 'as-is', without any express or implied
#  warranty. In no event will the authors be held liable for any damages
#  arising from the use of this software.
#
#  Permission is granted to anyone to use this software for any purpose,
#  including commercial applications, and to alter it and redistribute it
#  freely, subject to the following restrictions:
#
#  1. The origin of this software must not be misrepresented; you must not
#     claim that you wrote the original software. If you use this software
#     in a product, an acknowledgment in the product documentation would be
#     appreciated but is not required.
#  2. Altered source versions must be plainly marked as such, and must not be
#     misrepresented as being the original software.
#  3. This notice may not be removed or altered from any source distribution.
#

## Find scripts location and set variables
scriptdir="$( cd "$( dirname "$0" )" && pwd )"
repodir=`dirname $scriptdir`
workdir=$(pwd)

## Test for global and local config files
globalconfigcount=`ls $repodir/resources/akutils_RADseq.global.config 2>/dev/null | head -1 | wc -l`
globalconfigsearch=`ls $repodir/resources/akutils_RADseq.global.config 2>/dev/null | head -1`
localconfigcount=`ls akutils_RADseq*.config 2>/dev/null | head -1 | wc -l `
localconfigsearch=`ls akutils_RADseq*.config 2>/dev/null | head -1`

	if [[ $localconfigcount -eq 1 ]]; then
	configfile=($localconfigsearch)
	elif [[ $globalconfigcount -eq 1 ]]; then
	configfile=($globalconfigsearch)
	fi

echo $configfile

exit 0
