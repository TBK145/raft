#!/bin/bash

AMOUNT=${1:-3}

if [[ ! $AMOUNT =~ ^-?[0-9]+$ ]] || [[ $AMOUNT -le 2 ]] ; then
	echo "Argument is not an integer or not big enough (at least 3 nodes are required)"
	exit
fi

for NODE in 2 $AMOUNT
do
	elixir --sname $NODE -S mix run $NODE $AMOUNT
done

iex --sname 1 -S mix run 1 $AMOUNT
